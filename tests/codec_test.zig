const std = @import("std");
const testing = std.testing;
const codec = @import("codec");

test "variable length boundaries and canonical encodings" {
    const cases = .{
        .{ @as(u28, 0), "\x00" },
        .{ @as(u28, 0x7f), "\x7f" },
        .{ @as(u28, 0x80), "\x81\x00" },
        .{ @as(u28, 0x3fff), "\xff\x7f" },
        .{ @as(u28, 0x4000), "\x81\x80\x00" },
        .{ @as(u28, 0x1fffff), "\xff\xff\x7f" },
        .{ @as(u28, 0x200000), "\x81\x80\x80\x00" },
        .{ @as(u28, 0xfffffff), "\xff\xff\xff\x7f" },
    };

    inline for (cases) |case| {
        var buffer: [4]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);

        try codec.writeVariableLength(&writer, case[0]);
        try testing.expectEqualSlices(u8, case[1], writer.buffered());

        var cursor: codec.Cursor = .{ .bytes = writer.buffered() };

        try testing.expectEqual(case[0], try cursor.variableLength());
        try testing.expectEqual(@as(usize, 0), cursor.remaining().len);
    }

    var overflow: codec.Cursor = .{ .bytes = "\xff\xff\xff\xff\x00" };

    try testing.expectError(error.InvalidVariableLength, overflow.variableLength());

    var truncated: codec.Cursor = .{ .bytes = "\x80" };

    try testing.expectError(error.UnexpectedEnd, truncated.variableLength());
}
