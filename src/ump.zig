//! UMP framing and packet codecs. Raw packets preserve unknown message types and
//! reserved fields. Typed views interpret known fields; they are not a session validator.

const std = @import("std");
const midi = @import("midi.zig");
const live = @import("live.zig");
const midi2 = @import("midi2.zig");

pub const Error = error{
    UnexpectedEnd,
    TrailingData,
    InvalidPacketLength,
    InvalidMessageType,
    InvalidStatus,
    InvalidDataByte,
    InvalidPayloadLength,
    InvalidTiming,
};

/// Includes the specified sizes of reserved message types for forward-compatible framing.
pub fn wordCount(message_type: u4) u3 {
    return ([16]u3{ 1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4 })[message_type];
}

pub const Packet = struct {
    /// Host numeric words, never a native-endian byte buffer. Unused words are zero
    /// after parsing; only the words selected by messageType() are serialized.
    words: [4]u32,

    pub fn messageType(self: Packet) u4 {
        return @truncate(self.words[0] >> 28);
    }

    pub fn wordLength(self: Packet) u3 {
        return wordCount(self.messageType());
    }

    /// Reserved message types have unknown addressing, so return null too.
    pub fn group(self: Packet) ?u4 {
        return switch (self.messageType()) {
            1...5, 0xd => @truncate(self.words[0] >> 24),
            else => null,
        };
    }

    pub fn parseWords(input: []const u32) Error!Packet {
        if (input.len == 0)
            return error.UnexpectedEnd;
        const count = wordCount(@truncate(input[0] >> 28));
        if (input.len != count)
            return error.InvalidPacketLength;
        var packet: Packet = .{ .words = .{ 0, 0, 0, 0 } };

        @memcpy(packet.words[0..count], input);

        return packet;
    }

    /// Exactly one packet, words encoded most-significant byte first. This does
    /// not imply the byte order of any platform MIDI API's native word buffers.
    pub fn parse(bytes: []const u8) Error!Packet {
        var iterator: Iterator = .{ .bytes = bytes };
        const packet = try iterator.next() orelse return error.UnexpectedEnd;
        if (iterator.position != bytes.len)
            return error.TrailingData;

        return packet;
    }

    pub fn write(self: Packet, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.words[0..self.wordLength()]) |word| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, word, .big);
            try writer.writeAll(&bytes);
        }
    }

    pub fn fromMidi2(event: midi2.ChannelEvent) Packet {
        const data = event.words();

        return .{ .words = .{ data[0], data[1], 0, 0 } };
    }

    pub fn asMidi2(self: Packet) midi2.DecodeError!midi2.ChannelEvent {
        if (self.messageType() != 4)
            return error.InvalidMessageType;

        return midi2.ChannelEvent.parseWords(self.words[0..2]);
    }

    pub fn fromMidi1(group_number: u4, event: midi.ChannelEvent) Packet {
        var bytes: [3]u8 = @splat(0);
        var writer = std.Io.Writer.fixed(&bytes);
        event.write(&writer) catch unreachable;

        return .{ .words = .{
            0x20000000 |
                (@as(u32, group_number) << 24) |
                (@as(u32, bytes[0]) << 16) |
                (@as(u32, bytes[1]) << 8) |
                bytes[2],
            0,
            0,
            0,
        } };
    }

    pub fn asMidi1(self: Packet) Error!midi.ChannelEvent {
        if (self.messageType() != 2)
            return error.InvalidMessageType;
        const a = self.words[0];
        const status: u8 = @truncate(a >> 16);
        if (status < 0x80 or status > 0xef)
            return error.InvalidStatus;
        var bytes: [3]u8 = .{ status, @as(u7, @truncate(a >> 8)), @as(u7, @truncate(a)) };
        const count: usize = if (status >> 4 == 0xc or status >> 4 == 0xd) 2 else 3;

        return (live.Event.parse(bytes[0..count]) catch |err|
            return packetError(err)).midi;
    }

    pub fn fromSystem(group_number: u4, event: live.Event) Error!Packet {
        switch (event) {
            .midi, .sysex => return error.InvalidMessageType,
            else => {},
        }

        var bytes: [3]u8 = @splat(0);
        var writer = std.Io.Writer.fixed(&bytes);
        event.write(&writer) catch |err| return packetError(err);

        return .{ .words = .{
            0x10000000 |
                (@as(u32, group_number) << 24) |
                (@as(u32, bytes[0]) << 16) |
                (@as(u32, bytes[1]) << 8) |
                bytes[2],
            0,
            0,
            0,
        } };
    }

    pub fn asSystem(self: Packet) Error!live.Event {
        if (self.messageType() != 1)
            return error.InvalidMessageType;
        const a = self.words[0];
        const status: u8 = @truncate(a >> 16);
        const count: usize = switch (status) {
            0xf1, 0xf3 => 2,
            0xf2 => 3,
            0xf6, 0xf8, 0xfa, 0xfb, 0xfc, 0xfe, 0xff => 1,
            else => return error.InvalidStatus,
        };

        var bytes: [3]u8 = .{
            status,
            @as(u7, @truncate(a >> 8)),
            @as(u7, @truncate(a)),
        };

        return live.Event.parse(bytes[0..count]) catch |err|
            return packetError(err);
    }

    pub fn asUtility(self: Packet) Error!Utility {
        if (self.messageType() != 0)
            return error.InvalidMessageType;

        return switch (@as(u4, @truncate(self.words[0] >> 20))) {
            0 => .noop,
            1 => .{ .jr_clock = @truncate(self.words[0]) },
            2 => .{ .jr_timestamp = @truncate(self.words[0]) },
            3 => blk: {
                const ticks: u16 = @truncate(self.words[0]);
                if (ticks == 0)
                    return error.InvalidTiming;

                break :blk .{ .delta_ticks_per_quarter = ticks };
            },
            4 => .{ .delta_clockstamp = @truncate(self.words[0]) },
            else => error.InvalidStatus,
        };
    }

    pub fn asSysEx7(self: Packet) Error!SysEx7 {
        if (self.messageType() != 3)
            return error.InvalidMessageType;
        const form = try fragment(@truncate(self.words[0] >> 20));
        const length: u4 = @truncate(self.words[0] >> 16);
        if (length > 6)
            return error.InvalidPayloadLength;
        const bytes = self.toByteArray();
        var result: SysEx7 = .{
            .group = self.group().?,
            .form = form,
            .length = length,
        };

        for (bytes[2..][0..length], 0..) |value, i| {
            result.data[i] = @as(u7, @truncate(value));
        }

        return result;
    }

    pub fn asSysEx8(self: Packet) Error!SysEx8 {
        if (self.messageType() != 5)
            return error.InvalidMessageType;
        const form = try fragment(@truncate(self.words[0] >> 20));
        const count: u4 = @truncate(self.words[0] >> 16);
        const bytes = self.toByteArray();
        var result: SysEx8 = .{
            .group = self.group().?,
            .form = form,
            .stream_id = bytes[2],
        };

        if (count == 15 and form == .end) {
            result.abort = true;

            return result;
        }

        if (count == 0 or count > 14)
            return error.InvalidPayloadLength;
        result.length = count - 1;
        @memcpy(result.data[0..result.length], bytes[3..][0..result.length]);

        return result;
    }

    /// Only the first wordLength() * 4 bytes belong to this packet.
    pub fn toByteArray(self: Packet) [16]u8 {
        var output: [16]u8 = @splat(0);

        for (self.words, 0..) |word, i| {
            std.mem.writeInt(u32, output[i * 4 ..][0..4], word, .big);
        }

        return output;
    }
};

fn packetError(err: anyerror) Error {
    return switch (err) {
        error.InvalidDataByte => error.InvalidDataByte,
        error.UnexpectedEnd => error.UnexpectedEnd,
        else => error.InvalidStatus,
    };
}

/// Concatenated big-endian UMP packets. Failure leaves position unchanged.
pub const Iterator = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn next(self: *Iterator) Error!?Packet {
        if (self.position == self.bytes.len)
            return null;
        const remaining = self.bytes[self.position..];
        const count = wordCount(@truncate(remaining[0] >> 4));
        const length = @as(usize, count) * 4;
        if (remaining.len < length)
            return error.UnexpectedEnd;
        var packet: Packet = .{ .words = .{ 0, 0, 0, 0 } };

        for (0..count) |i|
            packet.words[i] = std.mem.readInt(
                u32,
                remaining[i * 4 ..][0..4],
                .big,
            );
        self.position += length;

        return packet;
    }
};

/// Concatenated native numeric words, for APIs that already deliver u32 arrays.
pub const WordIterator = struct {
    words: []const u32,
    position: usize = 0,

    pub fn next(self: *WordIterator) Error!?Packet {
        if (self.position == self.words.len)
            return null;
        const remaining = self.words[self.position..];
        const count = wordCount(@truncate(remaining[0] >> 28));
        if (remaining.len < count)
            return error.UnexpectedEnd;
        const packet = try Packet.parseWords(remaining[0..count]);
        self.position += count;

        return packet;
    }
};

pub const Utility = union(enum) {
    noop,
    jr_clock: u16,
    jr_timestamp: u16,
    delta_ticks_per_quarter: u16,
    delta_clockstamp: u20,

    pub fn packet(self: Utility) Error!Packet {
        const word: u32 = switch (self) {
            .noop => 0,
            .jr_clock => |v| 0x00100000 | @as(u32, v),
            .jr_timestamp => |v| 0x00200000 | @as(u32, v),
            .delta_ticks_per_quarter => |v| if (v == 0)
                return error.InvalidTiming
            else
                0x00300000 | @as(u32, v),
            .delta_clockstamp => |v| 0x00400000 | @as(u32, v),
        };

        return .{ .words = .{ word, 0, 0, 0 } };
    }
};

pub const Fragment = enum(u2) { complete, start, continuation, end };
fn fragment(value: u4) Error!Fragment {
    return std.enums.fromInt(Fragment, value) orelse error.InvalidStatus;
}

pub const SysEx7 = struct {
    group: u4 = 0,
    form: Fragment = .complete,
    length: u4 = 0,
    data: [6]u8 = @splat(0),

    pub fn packet(self: SysEx7) Error!Packet {
        if (self.length > 6)
            return error.InvalidPayloadLength;
        var output: [8]u8 = @splat(0);
        output[0] = 0x30 | @as(u8, self.group);
        output[1] = (@as(u8, @intFromEnum(self.form)) << 4) | self.length;

        for (self.data[0..self.length], 0..) |v, i| {
            if (v > 127)
                return error.InvalidDataByte;
            output[i + 2] = v;
        }

        return .{
            .words = .{
                std.mem.readInt(u32, output[0..4], .big),
                std.mem.readInt(u32, output[4..8], .big),
                0,
                0,
            },
        };
    }
};

pub const SysEx8 = struct {
    group: u4 = 0,
    form: Fragment = .complete,
    stream_id: u8 = 0,
    length: u4 = 0,
    data: [13]u8 = @splat(0),
    abort: bool = false,

    pub fn packet(self: SysEx8) Error!Packet {
        if (self.length > 13 or (self.abort and (self.form != .end or self.length != 0)))
            return error.InvalidPayloadLength;
        var output: [16]u8 = @splat(0);
        output[0] = 0x50 | @as(u8, self.group);

        const count: u8 = if (self.abort) 15 else @as(u8, self.length) + 1;
        output[1] = (@as(u8, @intFromEnum(self.form)) << 4) | count;
        output[2] = self.stream_id;
        @memcpy(output[3..][0..self.length], self.data[0..self.length]);

        var result: Packet = .{ .words = undefined };

        for (0..4) |i|
            result.words[i] = std.mem.readInt(
                u32,
                output[i * 4 ..][0..4],
                .big,
            );

        return result;
    }
};

/// Absolute ticks in a caller-defined timebase. Packet timestamp messages are
/// not automatically interpreted here.
pub const TimedPacket = @import("sequence.zig").Timed(Packet);

pub const ByteSource = struct {
    bytes: []const u8,

    pub fn openCursor(self: ByteSource) Iterator {
        return .{ .bytes = self.bytes };
    }
};

pub const WordSource = struct {
    words: []const u32,

    pub fn openCursor(self: WordSource) WordIterator {
        return .{ .words = self.words };
    }
};

/// Write raw packets from a repeatable source. Validate framing/traversal before
/// emitting bytes. The source must remain unchanged throughout both traversals.
/// Unknown message families and reserved bits are preserved, not interpreted.
/// This serializes packet words only; it is not a timed sequence file format.
pub fn writeSource(source: anytype, writer: *std.Io.Writer) !void {
    var cursor = source.openCursor();

    while (try cursor.next()) |_| {}
    cursor = source.openCursor();

    while (try cursor.next()) |packet| {
        try packet.write(writer);
    }
}
