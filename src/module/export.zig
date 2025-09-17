const std = @import("std");

pub const ExportedFunc = struct {
    name: []const u8,
    index: usize,
};

pub const Export = union(enum) {
    func: ExportedFunc,

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Export {
        const name_len = try reader.takeLeb128(u32);

        const data = try reader.take(@as(usize, name_len));
        const name = try allocator.alloc(u8, name_len);
        @memcpy(name, data);

        const kind = try reader.takeInt(u8, std.builtin.Endian.little);
        const index = try reader.takeLeb128(u32);

        return switch (kind) {
            0x00 => Export{ .func = ExportedFunc{
                .name = name,
                .index = @as(usize, index),
            } },
            else => unreachable,
        };
    }
};
