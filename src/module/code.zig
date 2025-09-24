const std = @import("std");
const ValueType = @import("type.zig").ValueType;

pub const Error = error{ UnknownInstruction, InvalidCode };

pub const Instruction = union(enum) {
    local_get: u32,
    local_set: u32,
    i32_store: struct { u32, u32 }, // align, offset
    i32_const: i32,
    i32_add,
    call: u32,
    end,

    pub fn parse(v: u8, reader: *std.Io.Reader) !Instruction {
        return switch (v) {
            0x20 => {
                const ix = try reader.takeLeb128(u32);
                return Instruction{ .local_get = ix };
            },
            0x21 => {
                const ix = try reader.takeLeb128(u32);
                return Instruction{ .local_set = ix };
            },
            0x36 => {
                const aln = try reader.takeLeb128(u32);
                const off = try reader.takeLeb128(u32);
                return Instruction{ .i32_store = .{ aln, off } };
            },
            0x41 => {
                const val = try reader.takeLeb128(i32);
                return Instruction{ .i32_const = val };
            },
            0x6A => .i32_add,
            0x0B => .end,
            0x10 => {
                const ix = try reader.takeLeb128(u32);
                return Instruction{ .call = ix };
            },
            else => Error.UnknownInstruction,
        };
    }
};

pub const Local = struct { count: u32, type: ValueType };

pub const Code = struct {
    locals: std.ArrayList(Local),
    instructions: std.ArrayList(Instruction),

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Code {
        // Function body size, not necessary for parsing.
        _ = reader.takeLeb128(u32) catch {
            return Error.InvalidCode;
        };

        const locals = try parseLocals(allocator, reader);
        const instructions = try parseInstructions(allocator, reader);

        return Code{ .locals = locals, .instructions = instructions };
    }
};

fn parseLocals(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) !std.ArrayList(Local) {
    const count = try reader.takeLeb128(u32);

    var lx = try std.ArrayList(Local).initCapacity(allocator, @as(usize, count));

    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const local_count = try reader.takeLeb128(u32);

        const raw_type = try reader.takeInt(u8, std.builtin.Endian.little);
        const local_type = try ValueType.fromU8(raw_type);

        const local = Local{ .count = local_count, .type = local_type };
        lx.appendAssumeCapacity(local);
    }

    return lx;
}

fn parseInstructions(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) !std.ArrayList(Instruction) {
    var ix = std.ArrayList(Instruction).empty;

    while (true) {
        const raw = try reader.takeInt(u8, std.builtin.Endian.little);
        const ins = try Instruction.parse(raw, reader);
        try ix.append(allocator, ins);

        if (ins == .end) {
            break;
        }
    }

    return ix;
}
