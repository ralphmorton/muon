const std = @import("std");
const Code = @import("code.zig").Code;
const Export = @import("export.zig").Export;
const FuncType = @import("type.zig").FuncType;

pub const Error = error{ InvalidHeader, UnknownSection, InvalidCodeSection, InvalidFunctionSection, InvalidTypeSection };

pub const SectionHeader = enum(u8) {
    custom,
    type,
    import,
    function,
    memory,
    exports,
    code,
    data,

    fn fromU8(v: u8) Error!SectionHeader {
        return switch (v) {
            0x00 => .custom,
            0x01 => .type,
            0x02 => .import,
            0x03 => .function,
            0x05 => .memory,
            0x07 => .exports,
            0x0a => .code,
            0x0b => .data,
            else => Error.UnknownSection,
        };
    }
};

pub const Section = union(SectionHeader) {
    custom,
    type: std.ArrayList(FuncType),
    import,
    function: std.ArrayList(usize),
    memory,
    exports: std.ArrayList(Export),
    code: std.ArrayList(Code),
    data,

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) Error!Section {
        const code = reader.takeInt(u8, std.builtin.Endian.little) catch {
            return Error.InvalidHeader;
        };

        // Section size, not necessary for parsing.
        _ = reader.takeLeb128(u32) catch {
            return Error.InvalidHeader;
        };

        const header = try SectionHeader.fromU8(code);

        return switch (header) {
            SectionHeader.custom => .custom,
            SectionHeader.type => {
                const types = parseArrayList(FuncType, allocator, reader) catch {
                    return Error.InvalidTypeSection;
                };
                return Section{ .type = types };
            },
            SectionHeader.function => {
                const funcs = parseFunctionSection(allocator, reader) catch {
                    return Error.InvalidFunctionSection;
                };
                return Section{ .function = funcs };
            },
            SectionHeader.exports => {
                const exports = parseArrayList(Export, allocator, reader) catch {
                    return Error.InvalidCodeSection;
                };
                return Section{ .exports = exports };
            },
            SectionHeader.code => {
                const codes = parseArrayList(Code, allocator, reader) catch {
                    return Error.InvalidCodeSection;
                };
                return Section{ .code = codes };
            },
            else => Error.UnknownSection,
        };
    }
};

fn parseArrayList(comptime T: type, allocator: std.mem.Allocator, reader: *std.Io.Reader) !std.ArrayList(T) {
    const count = try reader.takeLeb128(u32);
    var types = try std.ArrayList(T).initCapacity(allocator, @as(usize, count));

    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const func = try T.parse(allocator, reader);
        types.appendAssumeCapacity(func);
    }

    return types;
}

fn parseFunctionSection(allocator: std.mem.Allocator, reader: *std.Io.Reader) !std.ArrayList(usize) {
    const count = try reader.takeLeb128(u32);
    var funcs = try std.ArrayList(usize).initCapacity(allocator, @as(usize, count));

    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const ix = try reader.takeLeb128(u32);
        try funcs.append(allocator, ix);
    }

    return funcs;
}
