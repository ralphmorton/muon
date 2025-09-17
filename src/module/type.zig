const std = @import("std");

pub const Error = error{UnknownType};

pub const ValueType = enum(u8) {
    f64,
    f32,
    i64,
    i32,

    pub fn fromU8(v: u8) Error!ValueType {
        return switch (v) {
            0x7C => .f64,
            0x7D => .f32,
            0x7E => .i64,
            0x7F => .i32,
            else => Error.UnknownType,
        };
    }
};

pub const FuncType = struct {
    params: std.ArrayList(ValueType),
    result: std.ArrayList(ValueType),

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !FuncType {
        const code = try reader.takeInt(u8, std.builtin.Endian.little);

        if (code != 0x60) {
            // 0x60 means "function". No other signature types are supported by WASM at
            // time of writing.
            unreachable;
        }

        const params = try parseTypes(allocator, reader);
        const result = try parseTypes(allocator, reader);

        return FuncType{ .params = params, .result = result };
    }
};

fn parseTypes(allocator: std.mem.Allocator, reader: *std.Io.Reader) !std.ArrayList(ValueType) {
    const num = try reader.takeLeb128(u32);

    var tx = try std.ArrayList(ValueType).initCapacity(allocator, @as(usize, num));

    var index: u32 = 0;
    while (index < num) : (index += 1) {
        const raw = try reader.takeInt(u8, std.builtin.Endian.little);
        const t = try ValueType.fromU8(raw);

        tx.appendAssumeCapacity(t);
    }

    return tx;
}
