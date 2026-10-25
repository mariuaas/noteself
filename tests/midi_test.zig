const std = @import("std");
const testing = std.testing;
const noteself = @import("noteself");
const midi = noteself.midi1;
const smf = noteself.smf;
const live = noteself.live;

const end: smf.Event = .{ .kind = .{ .meta = .end_of_track } };
const note: smf.Event = .{ .kind = .{ .midi = .{
    .channel = 2,
    .message = .{ .note_on = .{ .key = 60, .velocity = 100 } },
} } };
const fixture = "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x01\xe0" ++
    "MTrk\x00\x00\x00\x0d\x00\x92\x3c\x64\x83\x60\x82\x3c\x00\x00\xff\x2f\x00";

test "every channel message round trips on every channel" {
    const messages: []const midi.Message = &.{
        .{ .note_off = .{ .key = 127, .velocity = 0 } },
        .{ .note_on = .{ .key = 0, .velocity = 127 } },
        .{ .poly_pressure = .{ .key = 60, .pressure = 64 } },
        .{ .control_change = .{ .controller = 127, .value = 127 } },
        .{ .program_change = 127 },
        .{ .channel_pressure = 0 },
        .{ .pitch_bend = 0 },
        .{ .pitch_bend = 8192 },
        .{ .pitch_bend = 16383 },
    };

    for (0..16) |channel| {
        for (messages) |message| {
            const event: live.Event = .{
                .midi = .{
                    .channel = @intCast(channel),
                    .message = message,
                },
            };

            var buffer: [3]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);

            try event.write(&writer);
            try testing.expectEqualDeep(event, try live.Event.parse(writer.buffered()));
        }
    }

    var buffer: [3]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try (live.Event{
        .midi = .{
            .channel = 0,
            .message = .{ .pitch_bend = 8192 },
        },
    }).write(&writer);
    try testing.expectEqualSlices(u8, "\xe0\x00\x40", writer.buffered());
}

test "live system messages round trip with wire encodings" {
    const cases = .{
        .{ live.Event{ .sysex = "\x01\x02\x7f" }, "\xf0\x01\x02\x7f\xf7" },
        .{ live.Event{ .sysex = "" }, "\xf0\xf7" },
        .{ live.Event{ .time_code = 127 }, "\xf1\x7f" },
        .{ live.Event{ .song_position = 8192 }, "\xf2\x00\x40" },
        .{ live.Event{ .song_select = 127 }, "\xf3\x7f" },
        .{ live.Event.tune_request, "\xf6" },
        .{ live.Event.timing_clock, "\xf8" },
        .{ live.Event.start, "\xfa" },
        .{ live.Event.continue_playback, "\xfb" },
        .{ live.Event.stop, "\xfc" },
        .{ live.Event.active_sensing, "\xfe" },
        .{ live.Event.reset, "\xff" },
    };

    inline for (cases) |case| {
        var buffer: [16]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        const event: live.Event = case[0];

        try event.write(&writer);
        try testing.expectEqualSlices(u8, case[1], writer.buffered());
        try testing.expectEqualDeep(event, try live.Event.parse(case[1]));
    }
}

test "live packets reject invalid status, data, truncation and trailing bytes" {
    try testing.expectError(error.UnexpectedEnd, live.Event.parse(""));
    try testing.expectError(error.InvalidStatus, live.Event.parse("\x3c\x40"));
    try testing.expectError(error.InvalidStatus, live.Event.parse("\xf4"));
    try testing.expectError(error.InvalidStatus, live.Event.parse("\xf5"));
    try testing.expectError(error.InvalidStatus, live.Event.parse("\xf9"));
    try testing.expectError(error.InvalidStatus, live.Event.parse("\xfd"));
    try testing.expectError(error.InvalidStatus, live.Event.parse("\xf7"));
    try testing.expectError(error.InvalidDataByte, live.Event.parse("\x90\x80\x00"));
    try testing.expectError(error.InvalidDataByte, live.Event.parse("\xf0\xf8\xf7"));
    try testing.expectError(error.UnexpectedEnd, live.Event.parse("\x90\x3c"));
    try testing.expectError(error.UnexpectedEnd, live.Event.parse("\xf0\x01"));
    try testing.expectError(error.TrailingData, live.Event.parse("\xf8\x00"));
}

test "read an independently encoded SMF and write the same bytes" {
    const file = try smf.File.parse(fixture);

    try file.validate();
    try testing.expectEqual(smf.Format.single_track, file.header.format);
    try testing.expectEqual(@as(u15, 480), file.header.timing.metrical);
    try testing.expectEqual(@as(u16, 1), file.track_count);

    var tracks = file.tracks();
    const track = (try tracks.next()).?;

    try testing.expectEqual(@intFromPtr(fixture.ptr) + 22, @intFromPtr(track.data.ptr));
    try testing.expectEqual(null, try tracks.next());

    var events = track.events();

    try testing.expectEqualDeep(note, (try events.next()).?);

    const off: smf.Event = .{
        .delta = 480,
        .kind = .{
            .midi = .{
                .channel = 2,
                .message = .{
                    .note_off = .{ .key = 60, .velocity = 0 },
                },
            },
        },
    };

    try testing.expectEqualDeep(off, (try events.next()).?);
    try testing.expectEqualDeep(end, (try events.next()).?);
    try testing.expectEqual(null, try events.next());

    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try smf.write(file.header, &.{&.{ note, off, end }}, &writer, .{});
    try testing.expectEqualSlices(u8, fixture, writer.buffered());
}

test "SMF running status and optional writer compression" {
    const data = "\x00\x92\x3c\x64\x01\x3d\x00\x00\xff\x2f\x00";
    var iterator = (smf.Track{ .data = data }).events();

    try testing.expectEqualDeep(note, (try iterator.next()).?);

    const second = (try iterator.next()).?;

    try testing.expectEqual(@as(u28, 1), second.delta);
    try testing.expectEqual(@as(u7, 61), second.kind.midi.message.note_on.key);
    try testing.expectEqual(@as(u7, 0), second.kind.midi.message.note_on.velocity);

    var compressed: [128]u8 = undefined;
    var compressed_writer = std.Io.Writer.fixed(&compressed);

    try smf.write(.{}, &.{&.{ note, second, end }}, &compressed_writer, .{});
    try testing.expectEqualSlices(u8, data, compressed_writer.buffered()[22..]);

    var explicit: [128]u8 = undefined;
    var explicit_writer = std.Io.Writer.fixed(&explicit);

    try smf.write(
        .{},
        &.{&.{ note, second, end }},
        &explicit_writer,
        .{ .running_status = false },
    );
    try testing.expectEqual(compressed_writer.end + 1, explicit_writer.end);
    try (try smf.File.parse(explicit_writer.buffered())).validate();
}

test "meta and sysex cancel running status" {
    const resets: []const []const u8 = &.{ "\xff\x01\x00", "\xf0\x01\xf7", "\xf7\x00" };

    for (resets) |reset| {
        var buffer: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);

        try writer.writeAll("\x00\x90\x3c\x64\x00");
        try writer.writeAll(reset);
        try writer.writeAll("\x00\x3d\x64\x00\xff\x2f\x00");

        var events = (smf.Track{ .data = writer.buffered() }).events();
        _ = try events.next();
        _ = try events.next();
        try testing.expectError(error.MissingRunningStatus, events.next());
    }
}

test "SMF preserves meta, sysex fragments and arbitrary escapes" {
    const events: []const smf.Event = &.{
        note,
        .{
            .delta = 0xfffffff,
            .kind = .{
                .meta = .{ .kind = 0x51, .data = "\x07\xa1\x20" },
            },
        },
        note,
        .{ .kind = .{ .meta = .{ .kind = 0x70, .data = "\xff\x00\x80" } } },
        .{ .kind = .{ .sysex = "\x43\x01" } },
        note,
        .{ .kind = .{ .escape = "\x02\xf7\xff" } },
        note,
        end,
    };

    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try smf.write(.{}, &.{events}, &output.writer, .{});

    const file = try smf.File.parse(output.written());

    try file.validate();

    var tracks = file.tracks();
    var iterator = (try tracks.next()).?.events();

    for (events) |event| {
        try testing.expectEqualDeep(event, (try iterator.next()).?);
    }

    try testing.expectEqual(null, try iterator.next());
    try testing.expectEqual(@as(u24, 500000), events[1].kind.meta.tempo().?);
    try testing.expectEqual(null, smf.Meta.end_of_track.tempo());
}

test "all formats and time divisions round trip" {
    const timings: []const smf.Timing = &.{
        .{ .metrical = 1 },
        .{ .metrical = 32767 },
        .{ .timecode = .{ .frame_rate = .fps24, .ticks_per_frame = 1 } },
        .{ .timecode = .{ .frame_rate = .fps25, .ticks_per_frame = 40 } },
        .{ .timecode = .{ .frame_rate = .drop29, .ticks_per_frame = 80 } },
        .{ .timecode = .{ .frame_rate = .fps30, .ticks_per_frame = 255 } },
    };

    for (timings) |timing| {
        for ([_]smf.Format{ .single_track, .simultaneous, .sequential }) |format| {
            const header: smf.Header = .{ .format = format, .timing = timing };
            const tracks: []const []const smf.Event = if (format == .single_track)
                &.{&.{end}}
            else
                &.{ &.{end}, &.{ note, end } };
            var buffer: [128]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);

            try smf.write(header, tracks, &writer, .{});

            const file = try smf.File.parse(writer.buffered());

            try file.validate();
            try testing.expectEqualDeep(header, file.header);
            try testing.expectEqual(tracks.len, file.track_count);
        }
    }

    try testing.expectEqual(@as(u16, 0xe350), try timings[4].encode());
    try testing.expectError(error.InvalidTiming, smf.Timing.decode(0));
    try testing.expectError(error.InvalidTiming, smf.Timing.decode(0xe450));
    try testing.expectError(error.InvalidTiming, smf.Timing.decode(0xe300));
}

test "extended headers and unknown chunks are skipped" {
    const bytes = "MThd\x00\x00\x00\x08\x00\x00\x00\x01\x01\xe0xx" ++
        "JUNK\x00\x00\x00\x03abc" ++ "MTrk\x00\x00\x00\x04\x00\xff\x2f\x00" ++
        "JUNK\x00\x00\x00\x00";
    const file = try smf.File.parse(bytes);

    try file.validate();

    var tracks = file.tracks();

    try testing.expectEqualSlices(u8, "\x00\xff\x2f\x00", (try tracks.next()).?.data);
    try testing.expectEqual(null, try tracks.next());
}

test "sequence number can be explicit or omitted" {
    try (smf.Meta{ .kind = 0x00, .data = "" }).validate();
    try (smf.Meta{ .kind = 0x00, .data = "\x00\x02" }).validate();
    try testing.expectError(
        error.InvalidMetaEvent,
        (smf.Meta{ .kind = 0x00, .data = "\x00" }).validate(),
    );
}

test "every truncated prefix of a valid file is rejected" {
    for (0..fixture.len) |length| {
        if (smf.File.parse(fixture[0..length])) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "invalid SMF headers and chunk sizes are rejected" {
    var bytes: [fixture.len]u8 = fixture.*;
    bytes[0] = 'X';
    try testing.expectError(error.InvalidHeader, smf.File.parse(&bytes));
    bytes = fixture.*;
    bytes[7] = 5;
    try testing.expectError(error.InvalidHeader, smf.File.parse(&bytes));
    bytes = fixture.*;
    bytes[9] = 3;
    try testing.expectError(error.InvalidFormat, smf.File.parse(&bytes));
    bytes = fixture.*;
    bytes[11] = 2;
    try testing.expectError(error.InvalidTrackCount, smf.File.parse(&bytes));
    bytes = fixture.*;
    bytes[12] = 0;
    bytes[13] = 0;
    try testing.expectError(error.InvalidTiming, smf.File.parse(&bytes));
    bytes = fixture.*;
    bytes[18] = 0xff;
    try testing.expectError(error.UnexpectedEnd, smf.File.parse(&bytes));
    bytes = fixture.*;
    bytes[11] = 0;
    try testing.expectError(error.InvalidTrackCount, smf.File.parse(&bytes));
}

test "malformed tracks fail without advancing the iterator" {
    const cases = .{
        .{ "", error.MissingEndOfTrack },
        .{ "\x00", error.UnexpectedEnd },
        .{ "\x00\x3c\x40", error.MissingRunningStatus },
        .{ "\x00\x90\x80\x00", error.InvalidDataByte },
        .{ "\x00\xf8", error.InvalidStatus },
        .{ "\x00\xff\x80\x00", error.InvalidDataByte },
        .{ "\x00\xff\x2f\x01\x00", error.InvalidMetaEvent },
        .{ "\x00\xff\x51\x02\x01\x02", error.InvalidMetaEvent },
        .{ "\x00\xff\x51\x03\x00\x00\x00", error.InvalidMetaEvent },
        .{ "\x00\xff\x20\x01\x10", error.InvalidMetaEvent },
        .{ "\x00\xff\x2f\x00\x00", error.DataAfterEndOfTrack },
        .{ "\x00\xf0\x02\x00", error.UnexpectedEnd },
        .{ "\x80\x80\x80\x80", error.InvalidVariableLength },
    };

    inline for (cases) |case| {
        var iterator = (smf.Track{ .data = case[0] }).events();

        try testing.expectError(case[1], iterator.next());
        try testing.expectEqual(@as(usize, 0), iterator.cursor.position);
        try testing.expectError(case[1], iterator.next());
    }

    var missing = (smf.Track{ .data = "\x00\x90\x3c\x40" }).events();
    _ = try missing.next();
    try testing.expectError(error.MissingEndOfTrack, missing.next());
}

test "writer validates the whole file before emitting bytes" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try testing.expectError(
        error.MissingEndOfTrack,
        smf.write(.{}, &.{&.{note}}, &writer, .{}),
    );
    try testing.expectError(
        error.DataAfterEndOfTrack,
        smf.write(.{}, &.{&.{ end, note }}, &writer, .{}),
    );
    try testing.expectError(
        error.InvalidTrackCount,
        smf.write(.{}, &.{}, &writer, .{}),
    );
    try testing.expectError(
        error.InvalidTrackCount,
        smf.write(.{}, &.{ &.{end}, &.{end} }, &writer, .{}),
    );
    try testing.expectError(
        error.InvalidTiming,
        smf.write(.{ .timing = .{ .metrical = 0 } }, &.{&.{end}}, &writer, .{}),
    );
    try testing.expectError(
        error.MissingEndOfTrack,
        smf.write(.{ .format = .simultaneous }, &.{ &.{end}, &.{note} }, &writer, .{}),
    );
    try testing.expectEqual(@as(usize, 0), writer.end);
    try testing.expectError(
        error.InvalidDataByte,
        (live.Event{ .sysex = "\x80" }).write(&writer),
    );
    try testing.expectEqual(@as(usize, 0), writer.end);
}

test "writer propagates output errors" {
    var buffer: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try testing.expectError(error.WriteFailed, smf.write(.{}, &.{&.{end}}, &writer, .{}));
    writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(error.WriteFailed, note.kind.midi.write(&writer));
}

test "arbitrary bounded input never panics" {
    var random = std.Random.DefaultPrng.init(0x4d494449);
    var buffer: [128]u8 = undefined;

    for (0..4000) |_| {
        const length = random.random().uintLessThan(usize, buffer.len + 1);
        const bytes = buffer[0..length];
        random.random().bytes(bytes);
        if (smf.File.parse(bytes)) |file| {
            file.validate() catch {};
        } else |_| {}
        (smf.Track{ .data = bytes }).validate() catch {};
        _ = live.Event.parse(bytes) catch {};
    }
}
