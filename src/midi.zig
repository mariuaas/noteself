const std = @import("std");
const codec = @import("codec.zig");

pub const Note = struct {
    key: u7,
    velocity: u7,
};
pub const PolyPressure = struct {
    key: u7,
    pressure: u7,
};
pub const ControlChange = struct {
    controller: u7,
    value: u7,
};

pub const Message = union(enum) {
    note_off: Note,
    note_on: Note,
    poly_pressure: PolyPressure,
    control_change: ControlChange,
    program_change: u7,
    channel_pressure: u7,
    pitch_bend: u14,

    pub fn status(self: Message, channel: u4) u8 {
        const kind: u8 = switch (self) {
            .note_off => 0x80,
            .note_on => 0x90,
            .poly_pressure => 0xa0,
            .control_change => 0xb0,
            .program_change => 0xc0,
            .channel_pressure => 0xd0,
            .pitch_bend => 0xe0,
        };

        return kind | channel;
    }

    pub fn writeData(self: Message, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .note_off, .note_on => |note| try writer.writeAll(&.{ note.key, note.velocity }),
            .poly_pressure => |pressure| try writer.writeAll(&.{ pressure.key, pressure.pressure }),
            .control_change => |control| try writer.writeAll(&.{
                control.controller,
                control.value,
            }),
            .program_change, .channel_pressure => |value| try writer.writeByte(value),
            .pitch_bend => |value| try writer.writeAll(
                &.{
                    @as(u7, @truncate(value)),
                    @intCast(value >> 7),
                },
            ),
        }
    }

    pub fn readData(status_byte: u8, cursor: *codec.Cursor) codec.ParseError!Message {
        if (status_byte < 0x80 or status_byte > 0xef)
            return error.InvalidStatus;
        const first = try cursor.dataByte();

        return switch (status_byte >> 4) {
            0x8 => .{ .note_off = .{ .key = first, .velocity = try cursor.dataByte() } },
            0x9 => .{ .note_on = .{ .key = first, .velocity = try cursor.dataByte() } },
            0xa => .{ .poly_pressure = .{ .key = first, .pressure = try cursor.dataByte() } },
            0xb => .{ .control_change = .{ .controller = first, .value = try cursor.dataByte() } },
            0xc => .{ .program_change = first },
            0xd => .{ .channel_pressure = first },
            0xe => .{ .pitch_bend = @as(u14, first) | (@as(u14, try cursor.dataByte()) << 7) },
            else => unreachable,
        };
    }
};

pub const ChannelEvent = struct {
    channel: u4,
    message: Message,

    pub fn write(self: ChannelEvent, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte(self.message.status(self.channel));
        try self.message.writeData(writer);
    }
};
