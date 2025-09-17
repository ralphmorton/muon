const std = @import("std");
const Module = @import("module.zig").Module;
const Instruction = @import("module/code.zig").Instruction;
const ValueType = @import("module/type.zig").ValueType;

pub const Error = InitError || ExecError;
pub const InitError = error{ MissingTypeSection, MissingFunctionSection, MissingExportSection, MissingCodeSection };
pub const ExecError = error{ MissingLocal, StackEmpty, FramesEmpty, NoSuchExport, NoSuchFunction };

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

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    module: Module,
    stack: std.ArrayList(Value),
    frames: std.ArrayList(Frame),

    pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Runtime {
        const module = try Module.init(allocator, reader);

        if (module.types == null) return InitError.MissingTypeSection;
        if (module.funcs == null) return InitError.MissingFunctionSection;
        if (module.exports == null) return InitError.MissingExportSection;
        if (module.codes == null) return InitError.MissingCodeSection;

        const stack = std.ArrayList(Value).empty;
        const frames = std.ArrayList(Frame).empty;

        return Runtime{ .allocator = allocator, .module = module, .stack = stack, .frames = frames };
    }

    pub fn deinit(self: *Runtime) void {
        self.stack.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    pub fn call(self: *Runtime, name: []const u8, args: []const Value) !?Value {
        var fix: ?usize = null;
        for (self.module.exports.?.items) |ex| {
            switch (ex) {
                .func => |f| {
                    if (std.mem.eql(u8, f.name, name)) {
                        fix = f.index;
                        break;
                    }
                },
            }
        }

        if (fix == null) return ExecError.NoSuchExport;
        if (self.module.funcs.?.items.len <= fix.?) return ExecError.NoSuchFunction;

        for (args) |v| {
            try self.pushStack(v);
        }

        const res = try self.invoke(fix.?);
        return res;
    }

    fn invoke(self: *Runtime, fix: usize) !?Value {
        try self.pushFrame(fix);

        const tix = self.module.funcs.?.items[fix];
        const typ = &self.module.types.?.items[tix];

        {
            errdefer self.reset();
            try self.exec();

            if (typ.result.items.len > 0) {
                const res = try self.popStack();
                return res;
            }

            return null;
        }
    }

    fn pushFrame(self: *Runtime, fix: usize) !void {
        const tix = self.module.funcs.?.items[fix];
        const typ = &self.module.types.?.items[tix];
        const code = &self.module.codes.?.items[fix];

        const lx_count = code.locals.items.len + typ.params.items.len;
        var lx = try std.ArrayList(Value).initCapacity(self.allocator, lx_count);

        // TODO: fix performance
        for (0..lx_count) |_| {
            const v = try self.popStack();
            lx.insertAssumeCapacity(0, v);
        }

        for (code.locals.items) |l| {
            const v = Value.default(l.type);
            try lx.appendNTimes(self.allocator, v, l.count);
        }

        const frame = Frame{
            .pc = -1,
            .sp = self.stack.items.len,
            .ix = &code.instructions,
            .ar = typ.result.items.len,
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

                    const a = left.asI32() orelse unreachable;
                    const b = right.asI32() orelse unreachable;

                    try self.pushStack(Value{ .i32 = a + b });
                },
                .call => |ix| {
                    if (self.module.funcs.?.items.len <= ix) return ExecError.NoSuchFunction;
                    try self.pushFrame(@as(usize, ix));
                },
                .end => {
                    var f = try (self.frames.pop() orelse ExecError.FramesEmpty);
                    try self.stack_unwind(&f);
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

    fn stack_unwind(self: *Runtime, frame: *Frame) !void {
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

    const binary = try std.fs.cwd().readFileAlloc("test/export-add.wasm", allocator, std.Io.Limit.unlimited);
    var reader = std.Io.Reader.fixed(binary);
    defer allocator.free(binary);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const args = [2]Value{
        Value{ .i32 = 1 },
        Value{ .i32 = 2 },
    };

    var rt = try Runtime.init(arena.allocator(), &reader);

    const res = try rt.call("add", &args);
    try std.testing.expect(res != null);
    try std.testing.expect(res.?.asI32() != null);
    try std.testing.expect(res.?.asI32().? == 3);
}

test "function calling" {
    var allocator = std.testing.allocator;

    const binary = try std.fs.cwd().readFileAlloc("test/call.wasm", allocator, std.Io.Limit.unlimited);
    var reader = std.Io.Reader.fixed(binary);
    defer allocator.free(binary);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var rt = try Runtime.init(arena.allocator(), &reader);

    const res = try rt.call("call_doubler", &[1]Value{Value{ .i32 = 2 }});
    try std.testing.expect(res != null);
    try std.testing.expect(res.?.asI32() != null);
    try std.testing.expect(res.?.asI32().? == 4);
}
