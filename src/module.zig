const std = @import("std");
const Code = @import("module/code.zig").Code;
const Export = @import("module/export.zig").Export;
const Import = @import("module/import.zig").Import;
const FuncType = @import("module/type.zig").FuncType;
const Section = @import("module/section.zig").Section;

pub const Error = error{ InvalidModuleHeader, ModuleParsingFailed };

pub const Module = struct {
    version: u32,
    types: ?std.ArrayList(FuncType),
    imports: ?std.ArrayList(Import),
    funcs: ?std.ArrayList(usize),
    exports: ?std.ArrayList(Export),
    codes: ?std.ArrayList(Code),

    pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Module {
        const magic = try reader.takeArray(4);
        if (!std.mem.eql(u8, magic, "\x00asm")) {
            return Error.InvalidModuleHeader;
        }

        const version_bytes = try reader.takeArray(4);
        const version = std.mem.readInt(u32, version_bytes, std.builtin.Endian.little);

        var types: ?std.ArrayList(FuncType) = null;
        var imports: ?std.ArrayList(Import) = null;
        var funcs: ?std.ArrayList(usize) = null;
        var exports: ?std.ArrayList(Export) = null;
        var codes: ?std.ArrayList(Code) = null;

        while (reader.peekByte() != std.Io.Reader.Error.EndOfStream) {
            const section = try Section.parse(allocator, reader);

            switch (section) {
                .custom => {}, // Not supporting custom sections
                .type => |tx| types = tx,
                .import => |ix| imports = ix,
                .function => |fx| funcs = fx,
                .exports => |ex| exports = ex,
                .code => |cx| codes = cx,
                else => unreachable,
            }
        }

        return Module{
            .version = version,
            .types = types,
            .imports = imports,
            .funcs = funcs,
            .exports = exports,
            .codes = codes,
        };
    }
};

test "init empty module" {
    var allocator = std.testing.allocator;

    const binary = try std.fs.cwd().readFileAlloc(
        "test/empty.wasm",
        allocator,
        std.Io.Limit.unlimited,
    );

    var reader = std.Io.Reader.fixed(binary);
    defer allocator.free(binary);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const module = try Module.init(arena.allocator(), &reader);

    try std.testing.expect(module.version == 1);
    try std.testing.expect(module.types == null);
    try std.testing.expect(module.funcs == null);
    try std.testing.expect(module.exports == null);
    try std.testing.expect(module.codes == null);
}

test "init trivial module" {
    var allocator = std.testing.allocator;

    const binary = try std.fs.cwd().readFileAlloc(
        "test/trivial.wasm",
        allocator,
        std.Io.Limit.unlimited,
    );

    var reader = std.Io.Reader.fixed(binary);
    defer allocator.free(binary);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const module = try Module.init(arena.allocator(), &reader);

    try std.testing.expect(module.version == 1);
    try std.testing.expect(module.types.?.items.len == 1);
    try std.testing.expect(module.funcs.?.items.len == 1);
    try std.testing.expect(module.exports == null);
    try std.testing.expect(module.codes.?.items.len == 1);

    const t = module.types.?.items[0];
    try std.testing.expect(t.params.items.len == 0);
    try std.testing.expect(t.result.items.len == 0);

    const f = module.funcs.?.items[0];
    try std.testing.expect(f == 0);

    const c = module.codes.?.items[0];
    try std.testing.expect(c.locals.items.len == 0);
    try std.testing.expect(c.instructions.items.len == 1);

    const i = c.instructions.items[0];
    try std.testing.expect(i == .end);
}

test "funcs" {
    var allocator = std.testing.allocator;

    const binary = try std.fs.cwd().readFileAlloc(
        "test/funcs.wasm",
        allocator,
        std.Io.Limit.unlimited,
    );

    var reader = std.Io.Reader.fixed(binary);
    defer allocator.free(binary);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const module = try Module.init(arena.allocator(), &reader);

    try std.testing.expect(module.version == 1);
    try std.testing.expect(module.types.?.items.len == 2);
    try std.testing.expect(module.funcs.?.items.len == 2);
    try std.testing.expect(module.exports == null);
    try std.testing.expect(module.codes.?.items.len == 2);

    const t1 = module.types.?.items[0];
    try std.testing.expect(t1.params.items.len == 2);
    try std.testing.expect(t1.params.items[0] == .i32);
    try std.testing.expect(t1.params.items[1] == .i64);
    try std.testing.expect(t1.result.items.len == 0);

    const t2 = module.types.?.items[1];
    try std.testing.expect(t2.params.items.len == 2);
    try std.testing.expect(t2.params.items[0] == .i64);
    try std.testing.expect(t2.params.items[1] == .i32);
    try std.testing.expect(t2.result.items.len == 2);
    try std.testing.expect(t2.result.items[0] == .i32);
    try std.testing.expect(t2.result.items[1] == .i64);

    const f1 = module.funcs.?.items[0];
    try std.testing.expect(f1 == 0);

    const f2 = module.funcs.?.items[1];
    try std.testing.expect(f2 == 1);

    const c1 = module.codes.?.items[0];
    try std.testing.expect(c1.locals.items.len == 0);
    try std.testing.expect(c1.instructions.items.len == 1);
    try std.testing.expect(c1.instructions.items[0] == .end);

    const c2 = module.codes.?.items[1];
    try std.testing.expect(c2.locals.items.len == 0);
    try std.testing.expect(c2.instructions.items.len == 3);
    try std.testing.expect(c2.instructions.items[0] == .local_get);
    try std.testing.expect(c2.instructions.items[0].local_get == 1);
    try std.testing.expect(c2.instructions.items[1] == .local_get);
    try std.testing.expect(c2.instructions.items[1].local_get == 0);
    try std.testing.expect(c2.instructions.items[2] == .end);
}

test "add" {
    var allocator = std.testing.allocator;

    const binary = try std.fs.cwd().readFileAlloc(
        "test/add.wasm",
        allocator,
        std.Io.Limit.unlimited,
    );

    var reader = std.Io.Reader.fixed(binary);
    defer allocator.free(binary);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const module = try Module.init(arena.allocator(), &reader);

    try std.testing.expect(module.version == 1);
    try std.testing.expect(module.types.?.items.len == 1);
    try std.testing.expect(module.funcs.?.items.len == 1);
    try std.testing.expect(module.exports == null);
    try std.testing.expect(module.codes.?.items.len == 1);

    const t = module.types.?.items[0];
    try std.testing.expect(t.params.items.len == 2);
    try std.testing.expect(t.params.items[0] == .i32);
    try std.testing.expect(t.params.items[1] == .i32);
    try std.testing.expect(t.result.items.len == 1);
    try std.testing.expect(t.result.items[0] == .i32);

    const f = module.funcs.?.items[0];
    try std.testing.expect(f == 0);

    const c = module.codes.?.items[0];
    try std.testing.expect(c.locals.items.len == 0);
    try std.testing.expect(c.instructions.items.len == 4);
    try std.testing.expect(c.instructions.items[0] == .local_get);
    try std.testing.expect(c.instructions.items[0].local_get == 0);
    try std.testing.expect(c.instructions.items[1] == .local_get);
    try std.testing.expect(c.instructions.items[1].local_get == 1);
    try std.testing.expect(c.instructions.items[2] == .i32_add);
    try std.testing.expect(c.instructions.items[3] == .end);
}

test "export-add" {
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

    const module = try Module.init(arena.allocator(), &reader);

    try std.testing.expect(module.version == 1);
    try std.testing.expect(module.types.?.items.len == 1);
    try std.testing.expect(module.funcs.?.items.len == 1);
    try std.testing.expect(module.exports.?.items.len == 1);
    try std.testing.expect(module.codes.?.items.len == 1);

    const t = module.types.?.items[0];
    try std.testing.expect(t.params.items.len == 2);
    try std.testing.expect(t.params.items[0] == .i32);
    try std.testing.expect(t.params.items[1] == .i32);
    try std.testing.expect(t.result.items.len == 1);
    try std.testing.expect(t.result.items[0] == .i32);

    const f = module.funcs.?.items[0];
    try std.testing.expect(f == 0);

    const e = module.exports.?.items[0];
    try std.testing.expect(std.mem.eql(u8, e.func.name, "add"));
    try std.testing.expect(e.func.index == 0);

    const c = module.codes.?.items[0];
    try std.testing.expect(c.locals.items.len == 0);
    try std.testing.expect(c.instructions.items.len == 4);
    try std.testing.expect(c.instructions.items[0] == .local_get);
    try std.testing.expect(c.instructions.items[0].local_get == 0);
    try std.testing.expect(c.instructions.items[1] == .local_get);
    try std.testing.expect(c.instructions.items[1].local_get == 1);
    try std.testing.expect(c.instructions.items[2] == .i32_add);
    try std.testing.expect(c.instructions.items[3] == .end);
}

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

    try std.testing.expect(module.version == 1);
    try std.testing.expect(module.types.?.items.len == 1);
    try std.testing.expect(module.funcs.?.items.len == 1);
    try std.testing.expect(module.imports.?.items.len == 1);
    try std.testing.expect(module.exports.?.items.len == 1);
    try std.testing.expect(module.codes.?.items.len == 1);

    const t = module.types.?.items[0];
    try std.testing.expect(t.params.items.len == 1);
    try std.testing.expect(t.params.items[0] == .i32);
    try std.testing.expect(t.result.items.len == 1);
    try std.testing.expect(t.result.items[0] == .i32);

    const f = module.funcs.?.items[0];
    try std.testing.expect(f == 0);

    const i = module.imports.?.items[0];
    try std.testing.expect(std.mem.eql(u8, i.mod, "env"));
    try std.testing.expect(std.mem.eql(u8, i.name, "add"));
    try std.testing.expect(i.imported.func == 0);

    const e = module.exports.?.items[0];
    try std.testing.expect(std.mem.eql(u8, e.func.name, "call_add"));
    try std.testing.expect(e.func.index == 1);

    const c = module.codes.?.items[0];
    try std.testing.expect(c.locals.items.len == 0);
    try std.testing.expect(c.instructions.items.len == 3);
    try std.testing.expect(c.instructions.items[0] == .local_get);
    try std.testing.expect(c.instructions.items[0].local_get == 0);
    try std.testing.expect(c.instructions.items[1] == .call);
    try std.testing.expect(c.instructions.items[1].call == 0);
    try std.testing.expect(c.instructions.items[2] == .end);
}

test "call" {
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

    const module = try Module.init(arena.allocator(), &reader);

    try std.testing.expect(module.version == 1);
    try std.testing.expect(module.types.?.items.len == 1);
    try std.testing.expect(module.funcs.?.items.len == 2);
    try std.testing.expect(module.exports.?.items.len == 1);
    try std.testing.expect(module.codes.?.items.len == 2);

    const t = module.types.?.items[0];
    try std.testing.expect(t.params.items.len == 1);
    try std.testing.expect(t.params.items[0] == .i32);
    try std.testing.expect(t.result.items.len == 1);
    try std.testing.expect(t.result.items[0] == .i32);

    const f1 = module.funcs.?.items[0];
    try std.testing.expect(f1 == 0);

    const f2 = module.funcs.?.items[1];
    try std.testing.expect(f2 == 0);

    const e = module.exports.?.items[0];
    try std.testing.expect(std.mem.eql(u8, e.func.name, "call_doubler"));
    try std.testing.expect(e.func.index == 0);

    const c1 = module.codes.?.items[0];
    try std.testing.expect(c1.locals.items.len == 0);
    try std.testing.expect(c1.instructions.items.len == 3);
    try std.testing.expect(c1.instructions.items[0] == .local_get);
    try std.testing.expect(c1.instructions.items[0].local_get == 0);
    try std.testing.expect(c1.instructions.items[1] == .call);
    try std.testing.expect(c1.instructions.items[1].call == 1);
    try std.testing.expect(c1.instructions.items[2] == .end);

    const c2 = module.codes.?.items[1];
    try std.testing.expect(c2.locals.items.len == 0);
    try std.testing.expect(c2.instructions.items.len == 4);
    try std.testing.expect(c2.instructions.items[0] == .local_get);
    try std.testing.expect(c2.instructions.items[0].local_get == 0);
    try std.testing.expect(c2.instructions.items[1] == .local_get);
    try std.testing.expect(c2.instructions.items[1].local_get == 0);
    try std.testing.expect(c2.instructions.items[2] == .i32_add);
    try std.testing.expect(c2.instructions.items[3] == .end);
}
