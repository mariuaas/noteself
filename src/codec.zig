const std = @import("std");

pub const ParseError = error{
    UnexpectedEnd,
    InvalidHeader,
    InvalidFormat,
    InvalidTiming,
    InvalidTrackCount,
    InvalidChunk,
    InvalidStatus,
    InvalidDataByte,
    InvalidVariableLength,
    MissingRunningStatus,
    InvalidMetaEvent,
    MissingEndOfTrack,
    DataAfterEndOfTrack,
    TrailingData,
};

pub const Cursor = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn remaining(self: Cursor) []const u8 {
        return self.bytes[self.position..];
    }

    pub fn take(self: *Cursor, length: usize) ParseError![]const u8 {
        if (length > self.bytes.len - self.position)
            return error.UnexpectedEnd;
        const bytes = self.bytes[self.position..][0..length];
        self.position += length;

        return bytes;
    }

    pub fn byte(self: *Cursor) ParseError!u8 {
        return (try self.take(1))[0];
    }

    pub fn dataByte(self: *Cursor) ParseError!u7 {
        const value = try self.byte();
        if (value > 0x7f)
            return error.InvalidDataByte;

        return @intCast(value);
    }

    pub fn int(self: *Cursor, comptime Int: type) ParseError!Int {
        return std.mem.readInt(
            Int,
            (try self.take(@sizeOf(Int)))[0..@sizeOf(Int)],
            .big,
        );
    }

    pub fn variableLength(self: *Cursor) ParseError!u28 {
        var value: u28 = 0;

        for (0..4) |_| {
            const part = try self.byte();
            value = (value << 7) | @as(u7, @truncate(part));
            if (part & 0x80 == 0)
                return value;
        }

        return error.InvalidVariableLength;
    }

    pub fn payload(self: *Cursor) ParseError![]const u8 {
        return self.take(try self.variableLength());
    }
};

pub fn writeInt(
    writer: *std.Io.Writer,
    comptime Int: type,
    value: Int,
) std.Io.Writer.Error!void {
    var bytes: [@sizeOf(Int)]u8 = undefined;
    std.mem.writeInt(Int, &bytes, value, .big);
    try writer.writeAll(&bytes);
}

pub fn writeVariableLength(
    writer: *std.Io.Writer,
    value: u28,
) std.Io.Writer.Error!void {
    var bytes: [4]u8 = undefined;
    var position: usize = bytes.len - 1;
    var remaining: u28 = value;
    bytes[position] = @as(u7, @truncate(remaining));
    remaining >>= 7;

    while (remaining != 0) : (remaining >>= 7) {
        position -= 1;
        bytes[position] = @as(u8, @as(u7, @truncate(remaining))) | 0x80;
    }

    try writer.writeAll(bytes[position..]);
}
