const std = @import("std");
const testing = std.testing;
const noteself = @import("noteself");
const ump = noteself.ump;
const midi2 = noteself.midi2;
const midi1 = noteself.midi1;
const live = noteself.live;

// Independent numeric fixtures transcribed from the field layouts in M2-104-UM
// v1.1.2, sections 7.3 / 7.4. They do not use the encoder to construct expectations.
test "every MIDI 2 channel message has the specified wire fields" {
    const Case = struct {
        message: midi2.Message,
        words: [2]u32,
    };
    const cases = [_]Case{
        .{
            .message = .{
                .registered_per_note_controller = .{
                    .key = 60,
                    .index = 3,
                    .value = 0x78000000,
                },
            },
            .words = .{ 0x42033c03, 0x78000000 },
        },
        .{
            .message = .{
                .assignable_per_note_controller = .{
                    .key = 60,
                    .index = 255,
                    .value = 0xffffffff,
                },
            },
            .words = .{ 0x42133cff, 0xffffffff },
        },
        .{
            .message = .{
                .registered_controller = .{
                    .bank = 1,
                    .index = 2,
                    .value = 0x12345678,
                },
            },
            .words = .{ 0x42230102, 0x12345678 },
        },
        .{
            .message = .{
                .assignable_controller = .{ .bank = 127, .index = 127, .value = 1 },
            },
            .words = .{ 0x42337f7f, 1 },
        },
        .{
            .message = .{
                .relative_registered_controller = .{ .bank = 0, .index = 1, .value = -1 },
            },
            .words = .{ 0x42430001, 0xffffffff },
        },
        .{
            .message = .{
                .relative_assignable_controller = .{
                    .bank = 2,
                    .index = 3,
                    .value = std.math.minInt(i32),
                },
            },
            .words = .{ 0x42530203, 0x80000000 },
        },
        .{
            .message = .{
                .per_note_pitch_bend = .{ .key = 60, .value = 0x80000000 },
            },
            .words = .{ 0x42633c00, 0x80000000 },
        },
        .{
            .message = .{
                .note_off = .{
                    .key = 60,
                    .velocity = 0x1234,
                    .attribute_type = 1,
                    .attribute_data = 0xabcd,
                },
            },
            .words = .{ 0x42833c01, 0x1234abcd },
        },
        .{
            .message = .{
                .note_on = .{
                    .key = 60,
                    .velocity = 0,
                    .attribute_type = 3,
                    .attribute_data = 0x7800,
                },
            },
            .words = .{ 0x42933c03, 0x00007800 },
        },
        .{
            .message = .{
                .poly_pressure = .{ .key = 60, .value = 0xffffffff },
            },
            .words = .{ 0x42a33c00, 0xffffffff },
        },
        .{
            .message = .{
                .control_change = .{ .controller = 7, .value = 0xabcdef01 },
            },
            .words = .{ 0x42b30700, 0xabcdef01 },
        },
        .{
            .message = .{
                .program_change = .{
                    .program = 5,
                    .bank = .{ .msb = 1, .lsb = 2 },
                },
            },
            .words = .{ 0x42c30001, 0x05000102 },
        },
        .{
            .message = .{ .program_change = .{ .program = 127 } },
            .words = .{ 0x42c30000, 0x7f000000 },
        },
        .{ .message = .{ .channel_pressure = 0x87654321 }, .words = .{ 0x42d30000, 0x87654321 } },
        .{ .message = .{ .pitch_bend = 0x80000000 }, .words = .{ 0x42e30000, 0x80000000 } },
        .{
            .message = .{
                .per_note_management = .{
                    .key = 60,
                    .detach = true,
                    .reset = true,
                },
            },
            .words = .{ 0x42f33c03, 0 },
        },
    };

    for (cases) |case| {
        const event: midi2.ChannelEvent = .{ .group = 2, .channel = 3, .message = case.message };

        try testing.expectEqualDeep(case.words, event.words());
        try testing.expectEqualDeep(event, try midi2.ChannelEvent.parseWords(&case.words));

        var buffer: [8]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);

        try event.write(&writer);

        const packet = try ump.Packet.parse(&buffer);

        try testing.expectEqualDeep(event, try packet.asMidi2());
        try testing.expectEqualDeep(packet, ump.Packet.fromMidi2(event));
    }
}

test "UMP framing preserves every message type at its allocated size" {
    const sizes = [_]usize{ 1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4 };
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var words: [40]u32 = undefined;
    var used: usize = 0;

    for (sizes, 0..) |count, kind| {
        const input: [4]u32 = .{
            (@as(u32, @intCast(kind)) << 28) | 0x01234567,
            0x89abcdef,
            0x01234567,
            0xfedcba98,
        };

        const packet = try ump.Packet.parseWords(input[0..count]);

        try testing.expectEqual(count, packet.wordLength());
        try packet.write(&writer);
        @memcpy(words[used..][0..count], input[0..count]);
        used += count;

        for (0..count * 4) |length| {
            const bytes = packet.toByteArray();

            try testing.expectError(error.UnexpectedEnd, ump.Packet.parse(bytes[0..length]));
        }
    }

    var iterator: ump.Iterator = .{ .bytes = writer.buffered() };
    var word_iterator: ump.WordIterator = .{ .words = words[0..used] };

    for (sizes, 0..) |_, kind| {
        const packet = (try iterator.next()).?;

        try testing.expectEqual(kind, packet.messageType());
        try testing.expectEqualDeep(packet, (try word_iterator.next()).?);
        if (kind == 0 or kind == 15 or (kind >= 6 and kind <= 12) or kind == 14) {
            try testing.expectEqual(null, packet.group());
        } else {
            try testing.expectEqual(@as(?u4, 1), packet.group());
        }
    }

    try testing.expectEqual(null, try iterator.next());
    try testing.expectEqual(null, try word_iterator.next());
    try testing.expectError(error.TrailingData, ump.Packet.parse(writer.buffered()));

    var short: ump.Iterator = .{ .bytes = "\x40\x90\x3c\x00\x80" };

    try testing.expectError(error.UnexpectedEnd, short.next());
    try testing.expectEqual(@as(usize, 0), short.position);

    var short_words: ump.WordIterator = .{ .words = &.{0x40903c00} };

    try testing.expectError(error.UnexpectedEnd, short_words.next());
    try testing.expectEqual(@as(usize, 0), short_words.position);
}

test "MIDI 1 remains distinct in UMP with all channels and group boundaries" {
    const messages = [_]midi1.Message{
        .{ .note_on = .{ .key = 60, .velocity = 0 } },
        .{ .note_off = .{ .key = 127, .velocity = 127 } },
        .{ .poly_pressure = .{ .key = 60, .pressure = 90 } },
        .{ .control_change = .{ .controller = 7, .value = 100 } },
        .{ .program_change = 127 },
        .{ .channel_pressure = 100 },
        .{ .pitch_bend = 8192 },
    };

    for (messages) |message| {
        for (0..16) |group| {
            for (0..16) |channel| {
                const event: midi1.ChannelEvent = .{
                    .channel = @intCast(channel),
                    .message = message,
                };

                const packet = ump.Packet.fromMidi1(@intCast(group), event);

                try testing.expectEqualDeep(event, try packet.asMidi1());
                try testing.expectEqual(@as(?u4, @intCast(group)), packet.group());
                try testing.expectError(error.InvalidMessageType, packet.asMidi2());
            }
        }
    }

    try testing.expectEqual(
        @as(u32, 0x20903c00),
        ump.Packet.fromMidi1(
            0,
            .{ .channel = 0, .message = messages[0] },
        ).words[0],
    );
    const bad = try ump.Packet.parseWords(&.{0x20908001});

    try testing.expectEqual(@as(u7, 0), (try bad.asMidi1()).message.note_on.key);
}

test "System and Utility fixtures and groupless addressing" {
    const events = [_]live.Event{
        .{ .time_code = 127 },
        .{ .song_position = 8192 },
        .{ .song_select = 5 },
        .tune_request,
        .timing_clock,
        .start,
        .continue_playback,
        .stop,
        .active_sensing,
        .reset,
    };

    const expected = [_]u32{
        0x1ff17f00,
        0x1ff20040,
        0x1ff30500,
        0x1ff60000,
        0x1ff80000,
        0x1ffa0000,
        0x1ffb0000,
        0x1ffc0000,
        0x1ffe0000,
        0x1fff0000,
    };

    for (events, expected) |event, word| {
        const packet = try ump.Packet.fromSystem(15, event);

        try testing.expectEqual(word, packet.words[0]);
        try testing.expectEqualDeep(event, try packet.asSystem());
    }

    try testing.expectError(error.InvalidMessageType, ump.Packet.fromSystem(0, .{ .sysex = "" }));

    const utilities = [_]ump.Utility{
        .noop,
        .{ .jr_clock = 0x1234 },
        .{ .jr_timestamp = 0xffff },
        .{ .delta_ticks_per_quarter = 960 },
        .{ .delta_clockstamp = 0xfffff },
    };

    const utility_words = [_]u32{ 0, 0x00101234, 0x0020ffff, 0x003003c0, 0x004fffff };

    for (utilities, utility_words) |utility, word| {
        const packet = try utility.packet();

        try testing.expectEqual(word, packet.words[0]);
        try testing.expectEqual(null, packet.group());
        try testing.expectEqualDeep(utility, try packet.asUtility());
    }

    try testing.expectError(
        error.InvalidTiming,
        (ump.Utility{ .delta_ticks_per_quarter = 0 }).packet(),
    );
}

test "SysEx7 and SysEx8 fragments match wire format including abort" {
    const seven: ump.SysEx7 = .{
        .group = 2,
        .form = .start,
        .length = 6,
        .data = .{ 0x7e, 1, 2, 3, 4, 5 },
    };

    const packet = try seven.packet();

    try testing.expectEqualDeep([4]u32{ 0x32167e01, 0x02030405, 0, 0 }, packet.words);
    try testing.expectEqualDeep(seven, try packet.asSysEx7());

    const reserved_bits = try ump.Packet.parseWords(&.{ 0x3001ff00, 0 });

    try testing.expectEqual(@as(u8, 127), (try reserved_bits.asSysEx7()).data[0]);

    for ([_]ump.Fragment{ .complete, .start, .continuation, .end }) |form| {
        for (0..7) |length| {
            const value: ump.SysEx7 = .{ .form = form, .length = @intCast(length) };

            try testing.expectEqualDeep(value, try (try value.packet()).asSysEx7());
        }

        for (0..14) |length| {
            var value: ump.SysEx8 = .{
                .form = form,
                .group = 15,
                .stream_id = 255,
                .length = @intCast(length),
            };

            @memset(value.data[0..length], 0xff);
            try testing.expectEqualDeep(value, try (try value.packet()).asSysEx8());
        }
    }

    const eight: ump.SysEx8 = .{
        .group = 1,
        .form = .end,
        .stream_id = 0xaa,
        .length = 2,
        .data = .{
            0x80,
            0xff,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        },
    };

    try testing.expectEqualDeep([4]u32{ 0x5133aa80, 0xff000000, 0, 0 }, (try eight.packet()).words);

    const abort: ump.SysEx8 = .{ .form = .end, .stream_id = 7, .abort = true };

    try testing.expectEqual(@as(u32, 0x503f0700), (try abort.packet()).words[0]);
    try testing.expectEqualDeep(abort, try (try abort.packet()).asSysEx8());
    try testing.expectError(error.InvalidPayloadLength, (ump.SysEx8{ .abort = true }).packet());
    try testing.expectError(error.InvalidPayloadLength, (ump.SysEx7{ .length = 7 }).packet());
    try testing.expectError(
        error.InvalidDataByte,
        (ump.SysEx7{
            .length = 1,
            .data = .{ 128, 0, 0, 0, 0, 0 },
        }).packet(),
    );
    try testing.expectError(
        error.InvalidPayloadLength,
        (try ump.Packet.parseWords(&.{ 0x50000000, 0, 0, 0 })).asSysEx8(),
    );
    try testing.expectError(
        error.InvalidStatus,
        (try ump.Packet.parseWords(&.{ 0x30400000, 0 })).asSysEx7(),
    );
}

test "typed MIDI2 ignores reserved fields while raw packets preserve them" {
    const packet = try ump.Packet.parseWords(&.{ 0x4fecffff, 0xdeadbeef });
    const event = try packet.asMidi2();

    try testing.expectEqual(@as(u4, 15), event.group);
    try testing.expectEqual(@as(u4, 12), event.channel);
    try testing.expectEqualDeep([2]u32{ 0x4fec0000, 0xdeadbeef }, event.words());
    try testing.expectEqual(@as(u32, 0x4fecffff), packet.words[0]);
    try testing.expectError(
        error.InvalidStatus,
        midi2.ChannelEvent.parseWords(&.{ 0x40700000, 0 }),
    );
    try testing.expectError(
        error.InvalidMessageType,
        midi2.ChannelEvent.parseWords(&.{ 0x20903c00, 0 }),
    );
    try testing.expectError(
        error.InvalidPacketLength,
        midi2.ChannelEvent.parseWords(&.{0x40903c00}),
    );
    var buffer: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try testing.expectError(error.WriteFailed, packet.write(&writer));
}

test "arbitrary UMP packets frame without panic and raw round trips are exact" {
    var rng = std.Random.DefaultPrng.init(0x554d50);
    var input: [16]u8 = undefined;

    for (0..4000) |_| {
        rng.random().bytes(&input);
        const length = @as(usize, ump.wordCount(@truncate(input[0] >> 4))) * 4;
        const packet = try ump.Packet.parse(input[0..length]);
        var output: [16]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);

        try packet.write(&writer);
        try testing.expectEqualSlices(u8, input[0..length], writer.buffered());
        _ = packet.asMidi1() catch null;
        _ = packet.asMidi2() catch null;
        _ = packet.asSystem() catch null;
        _ = packet.asUtility() catch null;
        _ = packet.asSysEx7() catch null;
        _ = packet.asSysEx8() catch null;
    }
}

test "MIDI2 addressing and native precision survive canonical encoding" {
    for (0..16) |group| {
        for (0..16) |channel| {
            for ([_]u16{ 0, 1, 0x8000, 0xffff }) |velocity| {
                const event: midi2.ChannelEvent = .{
                    .group = @intCast(group),
                    .channel = @intCast(channel),
                    .message = .{ .note_on = .{
                        .key = 127,
                        .velocity = velocity,
                        .attribute_type = 255,
                        .attribute_data = 65535,
                    } },
                };

                try testing.expectEqualDeep(event, try ump.Packet.fromMidi2(event).asMidi2());
            }
        }
    }

    var rng = std.Random.DefaultPrng.init(0x4d49444932);

    for (0..4000) |_| {
        const a = (rng.random().int(u32) & 0x0fffffff) | 0x40000000;
        const b = rng.random().int(u32);
        const event = midi2.ChannelEvent.parseWords(&.{ a, b }) catch |err| {
            try testing.expectEqual(error.InvalidStatus, err);
            continue;
        };

        const canonical = event.words();

        try testing.expectEqualDeep(event, try midi2.ChannelEvent.parseWords(&canonical));
    }

    const event: midi2.ChannelEvent = .{ .channel = 0, .message = .{ .pitch_bend = 0x80000000 } };
    var short: [7]u8 = undefined;
    var writer = std.Io.Writer.fixed(&short);

    try testing.expectError(error.WriteFailed, event.write(&writer));
}

test "UMP bytes are explicitly big endian rather than host native words" {
    const bytes = "\x42\x93\x3c\x03\x80\x00\x78\x00";
    const packet = try ump.Packet.parse(bytes);

    try testing.expectEqualDeep([4]u32{ 0x42933c03, 0x80007800, 0, 0 }, packet.words);
    try testing.expectEqual(@as(u16, 0x8000), (try packet.asMidi2()).message.note_on.velocity);

    var buffer: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try packet.write(&writer);
    try testing.expectEqualSlices(u8, bytes, writer.buffered());
}
