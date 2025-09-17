const std = @import("std");

pub const Imported = union(enum) {
    func: u32,
};

pub const Import = struct {
    mod: []const u8,
    name: []const u8,
    imported: Imported,

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Import {
        const mod_len = try reader.takeLeb128(u32);
        const mod_data = try reader.take(@as(usize, mod_len));
        const mod = try allocator.alloc(u8, mod_len);
        @memcpy(mod, mod_data);

        const name_len = try reader.takeLeb128(u32);
        const name_data = try reader.take(@as(usize, name_len));
        const name = try allocator.alloc(u8, name_len);
        @memcpy(name, name_data);

        const kind = try reader.takeInt(u8, std.builtin.Endian.little);
        const index = try reader.takeLeb128(u32);

        const imported = switch (kind) {
            0x00 => Imported{ .func = index },
            else => unreachable,
        };

        return Import{ .mod = mod, .name = name, .imported = imported };
    }
};
