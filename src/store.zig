const std = @import("std");
const Code = @import("module/code.zig").Code;
const Export = @import("module/export.zig").Export;
const FuncType = @import("module/type.zig").FuncType;
const Import = @import("module/import.zig").Import;
const Memory = @import("module/memory.zig").Memory;
const Module = @import("module.zig").Module;
const Segment = @import("module/data.zig").Segment;

pub const Error = error{
    NoSuchFuncType,
    NoSuchFunc,
    NoSuchMemory,
    MemoryAddressOutOfRange,
};

pub const Func = union(enum) {
    int: InternFunc,
    ext: ExternFunc,
};

pub const InternFunc = struct {
    type: *FuncType,
    code: *Code,
};

pub const ExternFunc = struct {
    mod: []const u8,
    name: []const u8,
    type: *FuncType,
};

const PAGE_SIZE: u32 = 65536;

pub const MemoryStore = struct {
    data: std.ArrayList(u8),
    max: ?u32,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    mod: Module,
    funcs: std.ArrayList(Func),
    memories: std.ArrayList(MemoryStore),
    externs: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator, mod: Module) !Store {
        const tx = mod.types orelse std.ArrayList(FuncType).empty;
        const ix = mod.imports orelse std.ArrayList(Import).empty;
        const fx = mod.funcs orelse std.ArrayList(usize).empty;
        const mx = mod.memory orelse std.ArrayList(Memory).empty;
        const ex = mod.exports orelse std.ArrayList(Export).empty;
        const cx = mod.codes orelse std.ArrayList(Code).empty;
        const sx = mod.data orelse std.ArrayList(Segment).empty;

        var funcs = std.ArrayList(Func).empty;

        for (ix.items) |imp| {
            switch (imp.imported) {
                .func => |i| {
                    if (tx.items.len <= i) return Error.NoSuchFuncType;

                    try funcs.append(
                        allocator,
                        Func{ .ext = ExternFunc{
                            .mod = imp.mod,
                            .name = imp.name,
                            .type = &tx.items[i],
                        } },
                    );
                },
            }
        }

        for (cx.items, 0..) |_, i| {
            if (fx.items.len <= i) return Error.NoSuchFunc;

            const tix = fx.items[i];
            if (tx.items.len <= tix) return Error.NoSuchFuncType;

            try funcs.append(
                allocator,
                Func{ .int = InternFunc{
                    .type = &tx.items[tix],
                    .code = &cx.items[i],
                } },
            );
        }

        var memories = std.ArrayList(MemoryStore).empty;

        for (mx.items) |mem| {
            var data = std.ArrayList(u8).empty;
            try data.appendNTimes(allocator, 0, mem.min * PAGE_SIZE);

            try memories.append(
                allocator,
                MemoryStore{
                    .data = data,
                    .max = mem.max,
                },
            );
        }

        var externs = std.StringHashMap(usize).init(allocator);

        for (ex.items) |exp| {
            switch (exp) {
                .func => |f| try externs.put(f.name, f.index),
            }
        }

        for (sx.items) |seg| {
            if (memories.items.len <= seg.memory) return Error.NoSuchMemory;

            const memory = &memories.items[seg.memory];
            if (memory.data.items.len < seg.offset + seg.init.len) return Error.MemoryAddressOutOfRange;

            @memcpy(memory.data.items[seg.offset..(seg.offset + seg.init.len)], seg.init);
        }

        return Store{
            .allocator = allocator,
            .mod = mod,
            .funcs = funcs,
            .memories = memories,
            .externs = externs,
        };
    }

    pub fn deinit(self: *Store) void {
        self.funcs.deinit(self.allocator);

        for (self.memories.items) |*mem| {
            mem.data.deinit(self.allocator);
        }
        self.memories.deinit(self.allocator);

        self.externs.deinit();
    }
};

test "import-add" {
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

    const module = try Module.init(arena.allocator(), &reader);
    const store = try Store.init(arena.allocator(), module);

    try std.testing.expect(store.funcs.items.len == 2);

    const f1 = store.funcs.items[0];
    try std.testing.expect(std.mem.eql(u8, f1.ext.mod, "env"));
    try std.testing.expect(std.mem.eql(u8, f1.ext.name, "add"));
    try std.testing.expect(f1.ext.type == &module.types.?.items[0]);

    const f2 = store.funcs.items[1];
    try std.testing.expect(f2.int.type == &module.types.?.items[0]);
    try std.testing.expect(f2.int.code == &module.codes.?.items[0]);
}
