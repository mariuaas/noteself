const std = @import("std");
const codec = @import("codec.zig");
const midi = @import("midi.zig");

pub const Event = union(enum) {
    midi: midi.ChannelEvent,
    sysex: []const u8,
    time_code: u7,
    song_position: u14,
    song_select: u7,
    tune_request,
    timing_clock,
    start,
    continue_playback,
    stop,
    active_sensing,
    reset,

    pub fn parse(bytes: []const u8) codec.ParseError!Event {
        var cursor: codec.Cursor = .{ .bytes = bytes };
        const status = try cursor.byte();
        const event: Event = switch (status) {
            0x80...0xef => .{ .midi = .{
                .channel = @truncate(status),
                .message = try midi.Message.readData(status, &cursor),
            } },
            0xf0 => result: {
                const remaining = cursor.remaining();
                if (remaining.len == 0 or remaining[remaining.len - 1] != 0xf7)
                    return error.UnexpectedEnd;
                const payload = remaining[0 .. remaining.len - 1];

                for (payload) |value| {
                    if (value > 0x7f)
                        return error.InvalidDataByte;
                }

                cursor.position = bytes.len;

                break :result .{ .sysex = payload };
            },
            0xf1 => .{ .time_code = try cursor.dataByte() },
            0xf2 => result: {
                const low = try cursor.dataByte();

                break :result .{
                    .song_position = @as(u14, low) | (@as(u14, try cursor.dataByte()) << 7),
                };
            },
            0xf3 => .{ .song_select = try cursor.dataByte() },
            0xf6 => .tune_request,
            0xf8 => .timing_clock,
            0xfa => .start,
            0xfb => .continue_playback,
            0xfc => .stop,
            0xfe => .active_sensing,
            0xff => .reset,
            else => return error.InvalidStatus,
        };

        if (cursor.remaining().len != 0)
            return error.TrailingData;

        return event;
    }

    pub fn write(
        self: Event,
        writer: *std.Io.Writer,
    ) (codec.ParseError || std.Io.Writer.Error)!void {
        switch (self) {
            .midi => |channel| try channel.write(writer),
            .sysex => |payload| {
                for (payload) |value| {
                    if (value > 0x7f)
                        return error.InvalidDataByte;
                }

                try writer.writeByte(0xf0);
                try writer.writeAll(payload);
                try writer.writeByte(0xf7);
            },
            .time_code => |value| try writer.writeAll(&.{ 0xf1, value }),
            .song_position => |value| try writer.writeAll(&.{
                0xf2,
                @as(u7, @truncate(value)),
                @intCast(value >> 7),
            }),
            .song_select => |value| try writer.writeAll(&.{ 0xf3, value }),
            .tune_request => try writer.writeByte(0xf6),
            .timing_clock => try writer.writeByte(0xf8),
            .start => try writer.writeByte(0xfa),
            .continue_playback => try writer.writeByte(0xfb),
            .stop => try writer.writeByte(0xfc),
            .active_sensing => try writer.writeByte(0xfe),
            .reset => try writer.writeByte(0xff),
        }
    }
};
