const std = @import("std");

pub const Segment = struct {
    memory: u32,
    offset: u32,
    init: []u8,

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Segment {
        const memory = try reader.takeLeb128(u32);
        const offset = try parseExpr(reader);

        const size = try reader.takeLeb128(u32);
        const data = try reader.take(@as(usize, size));
        const init = try allocator.alloc(u8, size);
        @memcpy(init, data);

        return Segment{
            .memory = memory,
            .offset = offset,
            .init = init,
        };
    }
};

// TODO: globals support
fn parseExpr(reader: *std.Io.Reader) !u32 {
    _ = try reader.takeLeb128(u32);
    const offset = try reader.takeLeb128(u32);
    _ = try reader.takeLeb128(u32);
    return offset;
}
