const std = @import("std");
const fun = @import("store.zig");
const Instruction = @import("module/code.zig").Instruction;
const Module = @import("module.zig").Module;
const Store = @import("store.zig").Store;
const ValueType = @import("module/type.zig").ValueType;

pub const Error = InitError || ExecError;

pub const InitError = error{
    MissingTypeSection,
    MissingFunctionSection,
    MissingExportSection,
    MissingCodeSection,
};

pub const ExecError = error{
    MissingLocal,
    StackEmpty,
    FramesEmpty,
    NoSuchExport,
    NoSuchExtern,
    NoSuchFunction,
};

pub const ExternError = error{InvalidArgs};

const Frame = struct {
    pc: isize,
    sp: usize,
    ix: *std.ArrayList(Instruction),
    ar: usize,
    lx: std.ArrayList(Value),
};

pub const Value = union(enum) {
    f64: f64,
    f32: f32,
    i64: i64,
    i32: i32,

    pub fn default(typ: ValueType) Value {
        return switch (typ) {
            .f64 => Value{ .f64 = 0 },
            .f32 => Value{ .f32 = 0 },
            .i64 => Value{ .i64 = 0 },
            .i32 => Value{ .i32 = 0 },
        };
    }

    pub fn asI32(self: Value) ?i32 {
        return switch (self) {
            .i32 => |v| v,
            else => null,
        };
    }
};

pub const Externs = std.StringHashMap(Extern);
pub const Extern = *const fn (*const std.ArrayList(Value)) ExternError!?Value;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    module: Module,
    store: Store,
    stack: std.ArrayList(Value),
    frames: std.ArrayList(Frame),
    externs: std.StringHashMap(Externs),

    pub fn init(
        allocator: std.mem.Allocator,
        externs: std.StringHashMap(Externs),
        reader: *std.Io.Reader,
    ) !Runtime {
        const module = try Module.init(allocator, reader);
        const store = try Store.init(allocator, module);

        const stack = std.ArrayList(Value).empty;
        const frames = std.ArrayList(Frame).empty;

        return Runtime{
            .allocator = allocator,
            .module = module,
            .store = store,
            .stack = stack,
            .frames = frames,
            .externs = externs,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.stack.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.store.deinit();

        var ext_iter = self.externs.iterator();
        while (ext_iter.next()) |ext| {
            ext.value_ptr.deinit();
        }

        self.externs.deinit();
    }

    pub fn call(self: *Runtime, name: []const u8, args: []const Value) !?Value {
        const fix: ?usize = self.store.externs.get(name);

        if (fix == null) return ExecError.NoSuchExport;
        if (self.store.funcs.items.len <= fix.?) return ExecError.NoSuchFunction;

        for (args) |v| {
            try self.pushStack(v);
        }

        const func = self.store.funcs.items[fix.?];

        const res = try switch (func) {
            .int => |f| self.invokeInternal(&f),
            .ext => |f| self.invokeExternal(&f),
        };

        return res;
    }

    fn invokeInternal(self: *Runtime, func: *const fun.InternFunc) !?Value {
        try self.pushFrame(func);

        {
            errdefer self.reset();
            try self.exec();

            if (func.type.result.items.len > 0) {
                const res = try self.popStack();
                return res;
            }

            return null;
        }
    }

    fn invokeExternal(self: *Runtime, func: *const fun.ExternFunc) !?Value {
        const exts = self.externs.get(func.mod);
        if (exts == null) return Error.NoSuchExtern;

        const ext = exts.?.get(func.name);
        if (ext == null) return Error.NoSuchExtern;

        const lx_count = func.type.params.items.len;
        var lx = try std.ArrayList(Value).initCapacity(self.allocator, lx_count);
        defer lx.deinit(self.allocator);

        for (0..lx_count) |_| {
            const v = try self.popStack();
            lx.insertAssumeCapacity(0, v);
        }

        const res = try ext.?(&lx);
        return res;
    }

    fn pushFrame(self: *Runtime, func: *const fun.InternFunc) !void {
        const lx_count = func.code.locals.items.len + func.type.params.items.len;
        var lx = try std.ArrayList(Value).initCapacity(self.allocator, lx_count);

        for (0..lx_count) |_| {
            const v = try self.popStack();
            lx.insertAssumeCapacity(0, v);
        }

        for (func.code.locals.items) |l| {
            const v = Value.default(l.type);
            try lx.appendNTimes(self.allocator, v, l.count);
        }

        const frame = Frame{
            .pc = -1,
            .sp = self.stack.items.len,
            .ix = &func.code.instructions,
            .ar = func.type.result.items.len,
            .lx = lx,
        };

        try self.frames.append(self.allocator, frame);
    }

    fn reset(self: *Runtime) void {
        self.stack.clearAndFree(self.allocator);
        self.frames.clearAndFree(self.allocator);
    }

    fn exec(self: *Runtime) !void {
        while (true) {
            if (self.frames.items.len == 0) break;

            var frame = &self.frames.items[self.frames.items.len - 1];
            frame.pc += 1;

            if (frame.pc >= frame.ix.items.len) break;

            const i = frame.ix.items[@intCast(frame.pc)];
            switch (i) {
                .local_get => |ix| {
                    if (frame.lx.items.len <= ix) return ExecError.MissingLocal;
                    try self.stack.append(self.allocator, frame.lx.items[ix]);
                },
                .i32_add => {
                    const right = try self.popStack();
                    const left = try self.popStack();

                    try self.pushStack(Value{ .i32 = left.i32 + right.i32 });
                },
                .call => |ix| {
                    if (self.store.funcs.items.len <= ix) return ExecError.NoSuchFunction;

                    try switch (self.store.funcs.items[ix]) {
                        .int => |f| self.pushFrame(&f),
                        .ext => |f| {
                            const v = try self.invokeExternal(&f);
                            if (v != null) {
                                try self.pushStack(v.?);
                            }
                        },
                    };
                },
                .end => {
                    var f = try (self.frames.pop() orelse ExecError.FramesEmpty);
                    try self.unwind(&f);
                },
            }
        }
    }

    inline fn popStack(self: *Runtime) !Value {
        return self.stack.pop() orelse ExecError.StackEmpty;
    }

    inline fn pushStack(self: *Runtime, v: Value) !void {
        try self.stack.append(self.allocator, v);
    }

    fn unwind(self: *Runtime, frame: *Frame) !void {
        frame.lx.deinit(self.allocator);

        if (frame.ar > 0) {
            const v = try self.popStack();
            self.stack.shrinkRetainingCapacity(frame.sp);
            try self.pushStack(v);
        } else {
            self.stack.shrinkRetainingCapacity(frame.sp);
        }
    }
};

test "add" {
    var allocator = std.testing.allocator;

    const binary = try std.fs.cwd().readFileAlloc(
        "test/export-add.wasm",
        allocator,
        std.Io.Limit.unlimited,
    );

    var reader = std.Io.Reader.fixed(binary);
    defer allocator.free(binary);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const args = [2]Value{
        Value{ .i32 = 1 },
        Value{ .i32 = 2 },
    };

    var rt = try Runtime.init(
        arena.allocator(),
        std.StringHashMap(Externs).init(allocator),
        &reader,
    );

    defer rt.deinit();

    const res = try rt.call("add", &args);
    try std.testing.expect(res != null);
    try std.testing.expect(res.?.asI32() != null);
    try std.testing.expect(res.?.asI32().? == 3);
}

test "function calling" {
    var allocator = std.testing.allocator;

    const binary = try std.fs.cwd().readFileAlloc(
        "test/call.wasm",
        allocator,
        std.Io.Limit.unlimited,
    );

    var reader = std.Io.Reader.fixed(binary);
    defer allocator.free(binary);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var rt = try Runtime.init(
        arena.allocator(),
        std.StringHashMap(Externs).init(allocator),
        &reader,
    );

    const res = try rt.call("call_doubler", &[1]Value{Value{ .i32 = 2 }});
    try std.testing.expect(res != null);
    try std.testing.expect(res.?.asI32() != null);
    try std.testing.expect(res.?.asI32().? == 4);
}

test "import" {
    var allocator = std.testing.allocator;

    const binary = try std.fs.cwd().readFileAlloc(
        "test/import-add.wasm",
        allocator,
        std.Io.Limit.unlimited,
    );

    var reader = std.Io.Reader.fixed(binary);
    defer allocator.free(binary);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var env = std.StringHashMap(Extern).init(allocator);
    try env.put("add", &testAdd);

    var externs = std.StringHashMap(Externs).init(allocator);
    try externs.put("env", env);

    var rt = try Runtime.init(
        arena.allocator(),
        externs,
        &reader,
    );

    defer rt.deinit();

    const res = try rt.call("call_add", &[1]Value{Value{ .i32 = 2 }});
    try std.testing.expect(res != null);
    try std.testing.expect(res.?.asI32() != null);
    try std.testing.expect(res.?.asI32().? == 3);
}

fn testAdd(vx: *const std.ArrayList(Value)) ExternError!?Value {
    if (vx.items.len != 1) return ExternError.InvalidArgs;

    const a = try switch (vx.items[0]) {
        .i32 => |v| v,
        else => ExternError.InvalidArgs,
    };

    return Value{ .i32 = a + 1 };
}
