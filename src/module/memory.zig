const std = @import("std");

pub const Memory = struct {
    min: u32,
    max: ?u32,

    pub fn parse(_: std.mem.Allocator, reader: *std.Io.Reader) !Memory {
        const flags = try reader.takeLeb128(u32);
        const min = try reader.takeLeb128(u32);
        var max: ?u32 = null;

        if (flags != 0) {
            max = try reader.takeLeb128(u32);
        }

        return Memory{ .min = min, .max = max };
    }
};
