const std = @import("std");
const rt = @import("runtime.zig");

pub const Runtime = rt.Runtime;
pub const Externs = rt.Externs;
pub const Extern = rt.Extern;
pub const ExternError = rt.ExternError;
pub const Value = rt.Value;

test "double" {
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

    var runtime = try Runtime.init(
        arena.allocator(),
        &std.StringHashMap(rt.Externs).init(allocator),
        &reader,
    );

    const res = try runtime.call("call_doubler", &[1]Value{Value{ .i32 = 2 }});
    try std.testing.expect(res != null);
    try std.testing.expect(res.?.asI32() != null);
    try std.testing.expect(res.?.asI32().? == 4);
}
