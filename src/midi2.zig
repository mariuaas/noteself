//! MIDI 2.0 Channel Voice messages (UMP MT 0x4). No implicit protocol conversion.

const std = @import("std");

pub const DecodeError = error{
    InvalidPacketLength,
    InvalidMessageType,
    InvalidStatus,
};

pub const Note = struct {
    key: u7,
    velocity: u16,
    attribute_type: u8 = 0,
    attribute_data: u16 = 0,
};

pub const PerNoteController = struct {
    key: u7,
    index: u8,
    value: u32,
};

pub const Controller = struct {
    bank: u7,
    index: u7,
    value: u32,
};

pub const RelativeController = struct {
    bank: u7,
    index: u7,
    value: i32,
};

pub const KeyValue = struct {
    key: u7,
    value: u32,
};

pub const Bank = struct {
    msb: u7,
    lsb: u7,
};

pub const Program = struct {
    program: u7,
    bank: ?Bank = null,
};

pub const Management = struct {
    key: u7,
    detach: bool = false,
    reset: bool = false,
};

pub const Message = union(enum) {
    registered_per_note_controller: PerNoteController,
    assignable_per_note_controller: PerNoteController,
    registered_controller: Controller,
    assignable_controller: Controller,
    relative_registered_controller: RelativeController,
    relative_assignable_controller: RelativeController,
    per_note_pitch_bend: KeyValue,
    note_off: Note,
    note_on: Note,
    poly_pressure: KeyValue,
    control_change: struct {
        controller: u7,
        value: u32,
    },
    program_change: Program,
    channel_pressure: u32,
    pitch_bend: u32,
    per_note_management: Management,
};

pub const ChannelEvent = struct {
    group: u4 = 0,
    channel: u4,
    message: Message,

    /// Host numeric words; word zero contains the message type in its high nibble.
    /// Reserved bits are emitted as zero. Native byte order is NOT specified here.
    pub fn words(self: ChannelEvent) [2]u32 {
        var first: u32 = 0x40000000 |
            (@as(u32, self.group) << 24) |
            (@as(u32, self.channel) << 16);
        var second: u32 = 0;
        const opcode: u4 = switch (self.message) {
            .registered_per_note_controller, .assignable_per_note_controller => |value| blk: {
                first |= (@as(u32, value.key) << 8) | value.index;
                second = value.value;

                break :blk if (self.message == .registered_per_note_controller) 0 else 1;
            },
            .registered_controller, .assignable_controller => |value| blk: {
                first |= (@as(u32, value.bank) << 8) | value.index;
                second = value.value;

                break :blk if (self.message == .registered_controller) 2 else 3;
            },
            .relative_registered_controller, .relative_assignable_controller => |value| blk: {
                first |= (@as(u32, value.bank) << 8) | value.index;
                second = @bitCast(value.value);

                break :blk if (self.message == .relative_registered_controller) 4 else 5;
            },
            .per_note_pitch_bend, .poly_pressure => |value| blk: {
                first |= @as(u32, value.key) << 8;
                second = value.value;

                break :blk if (self.message == .per_note_pitch_bend) 6 else 0xa;
            },
            .note_off, .note_on => |value| blk: {
                first |= (@as(u32, value.key) << 8) | value.attribute_type;
                second = (@as(u32, value.velocity) << 16) | value.attribute_data;

                break :blk if (self.message == .note_off) 8 else 9;
            },
            .control_change => |value| blk: {
                first |= @as(u32, value.controller) << 8;
                second = value.value;

                break :blk 0xb;
            },
            .program_change => |value| blk: {
                second = @as(u32, value.program) << 24;
                if (value.bank) |bank| {
                    first |= 1;
                    second |= (@as(u32, bank.msb) << 8) | bank.lsb;
                }

                break :blk 0xc;
            },
            .channel_pressure, .pitch_bend => |value| blk: {
                second = value;

                break :blk if (self.message == .channel_pressure) 0xd else 0xe;
            },
            .per_note_management => |value| blk: {
                first |= (@as(u32, value.key) << 8) |
                    (@as(u32, @intFromBool(value.detach)) << 1) |
                    @intFromBool(value.reset);

                break :blk 0xf;
            },
        };

        first |= @as(u32, opcode) << 20;

        return .{ first, second };
    }

    /// Ignores reserved fields as required for receivers. Keep the raw UMP when
    /// byte-for-byte preservation of those fields is needed.
    pub fn parseWords(input: []const u32) DecodeError!ChannelEvent {
        if (input.len != 2)
            return error.InvalidPacketLength;
        const first = input[0];
        const second = input[1];
        if (first >> 28 != 4)
            return error.InvalidMessageType;
        const key: u7 = @truncate(first >> 8);
        const index: u7 = @truncate(first);
        const message: Message = switch (@as(u4, @truncate(first >> 20))) {
            0 => .{
                .registered_per_note_controller = .{
                    .key = key,
                    .index = @truncate(first),
                    .value = second,
                },
            },
            1 => .{
                .assignable_per_note_controller = .{
                    .key = key,
                    .index = @truncate(first),
                    .value = second,
                },
            },
            2 => .{ .registered_controller = .{ .bank = key, .index = index, .value = second } },
            3 => .{ .assignable_controller = .{ .bank = key, .index = index, .value = second } },
            4 => .{
                .relative_registered_controller = .{
                    .bank = key,
                    .index = index,
                    .value = @bitCast(second),
                },
            },
            5 => .{
                .relative_assignable_controller = .{
                    .bank = key,
                    .index = index,
                    .value = @bitCast(second),
                },
            },
            6 => .{ .per_note_pitch_bend = .{ .key = key, .value = second } },
            7 => return error.InvalidStatus,
            8 => .{
                .note_off = .{
                    .key = key,
                    .velocity = @truncate(second >> 16),
                    .attribute_type = @truncate(first),
                    .attribute_data = @truncate(second),
                },
            },
            9 => .{
                .note_on = .{
                    .key = key,
                    .velocity = @truncate(second >> 16),
                    .attribute_type = @truncate(first),
                    .attribute_data = @truncate(second),
                },
            },
            0xa => .{ .poly_pressure = .{ .key = key, .value = second } },
            0xb => .{ .control_change = .{ .controller = key, .value = second } },
            0xc => .{
                .program_change = .{
                    .program = @truncate(second >> 24),
                    .bank = if (first & 1 != 0) .{
                        .msb = @truncate(second >> 8),
                        .lsb = @truncate(second),
                    } else null,
                },
            },
            0xd => .{ .channel_pressure = second },
            0xe => .{ .pitch_bend = second },
            0xf => .{
                .per_note_management = .{
                    .key = key,
                    .detach = first & 2 != 0,
                    .reset = first & 1 != 0,
                },
            },
        };

        return .{
            .group = @truncate(first >> 24),
            .channel = @truncate(first >> 16),
            .message = message,
        };
    }

    /// Big-endian byte serialization of UMP words, independent of the host ABI.
    pub fn write(self: ChannelEvent, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.words()) |word| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, word, .big);
            try writer.writeAll(&bytes);
        }
    }
};
