const std = @import("std");
const testing = std.testing;
const noteself = @import("noteself");
const smf = noteself.smf;
const ump = noteself.ump;
const sequence = noteself.sequence;
const document = noteself.document;

const fixture = "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x01\xe0" ++
    "MTrk\x00\x00\x00\x0d\x00\x92\x3c\x64\x83\x60\x82\x3c\x00\x00\xff\x2f\x00";
const on: smf.Event.Kind = .{
    .midi = .{
        .channel = 2,
        .message = .{
            .note_on = .{ .key = 60, .velocity = 100 },
        },
    },
};

const off: smf.Event.Kind = .{
    .midi = .{
        .channel = 2,
        .message = .{
            .note_off = .{ .key = 60, .velocity = 0 },
        },
    },
};

const end: smf.Event.Kind = .{ .meta = .end_of_track };
const notes: []const smf.TimedEvent = &.{
    .{ .tick = 0, .event = on },
    .{ .tick = 480, .event = off },
    .{ .tick = 480, .event = end },
};

const source: smf.TimedSliceSource = .{ .items = &.{notes} };

const rich: []const smf.TimedEvent = &.{
    .{ .tick = 0, .event = .{ .meta = .{ .kind = 0x51, .data = "\x07\xa1\x20" } } },
    .{ .tick = 0, .event = .{ .meta = .{ .kind = 0x70, .data = "\xff\x80\x00" } } },
    .{ .tick = 0, .event = .{ .sysex = "\x43\x01" } },
    .{ .tick = 10, .event = .{ .escape = "\x02\xf7\xff" } },
    .{ .tick = 10, .event = on },
    .{ .tick = 10, .event = off },
    .{ .tick = 20, .event = end },
};

const rich_source: smf.TimedSliceSource = .{ .items = &.{rich} };

fn expectTrack(expected: []const smf.TimedEvent, input: anytype) !void {
    var cursor = input;

    for (expected) |event| {
        try testing.expectEqualDeep(event, (try cursor.next()).?);
    }

    try testing.expectEqual(null, try cursor.next());
}

test "absolute cursor and repeatable source retain the existing SMF fixture" {
    const file = try smf.File.parse(fixture);
    var tracks = file.openTracks();
    const track = (try tracks.next()).?;

    try expectTrack(notes, track.openCursor());
    try expectTrack(notes, track.openCursor());

    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try smf.writeSource(file.header, file, &writer, .{});
    try testing.expectEqualSlices(u8, fixture, writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try smf.writeSource(file.header, source, &writer, .{});
    try testing.expectEqualSlices(u8, fixture, writer.buffered());
}

test "owned SMF detaches all payloads from input and cloning detaches the document" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try smf.writeSource(.{}, rich_source, &writer, .{});

    var doc = try document.Smf.parse(testing.allocator, writer.buffered());
    defer doc.deinit();
    @memset(&buffer, 0xaa);
    try expectTrack(rich, doc.tracks.items[0].openCursor());

    var cloned = try doc.clone(testing.allocator);
    defer cloned.deinit();
    try doc.tracks.items[0].replace(
        1,
        .{
            .tick = 0,
            .event = .{
                .meta = .{ .kind = 1, .data = "different" },
            },
        },
    );
    try doc.tracks.items[0].remove(2);
    doc.tracks.items[0].events.items[3].event.midi.message.note_on.velocity = 1;
    try expectTrack(rich, cloned.tracks.items[0].openCursor());
    try doc.removeTrack(0);
    try expectTrack(rich, cloned.tracks.items[0].openCursor());
}

test "track mutations copy payloads and preserve equal-time event order" {
    var doc = document.Smf.init(testing.allocator, .{});
    defer doc.deinit();
    const index = try doc.addTrack();
    const track = &doc.tracks.items[index];

    try track.append(.{ .tick = 480, .event = end });
    try track.insert(0, .{ .tick = 0, .event = on });
    try track.insert(1, .{ .tick = 480, .event = off });

    var payload = [_]u8{ 'a', 'b' };

    try track.insert(1, .{ .tick = 0, .event = .{ .meta = .{ .kind = 1, .data = &payload } } });
    payload[0] = 'c';
    try testing.expectEqualSlices(u8, "ab", track.events.items[1].event.meta.data);
    try track.replace(1, .{ .tick = 0, .event = .{ .meta = .{ .kind = 1, .data = &payload } } });
    payload[1] = 'd';
    try testing.expectEqualSlices(u8, "cb", track.events.items[1].event.meta.data);
    try track.remove(1);
    try expectTrack(notes, track.openCursor());
    try testing.expectError(error.InvalidIndex, track.insert(4, notes[0]));
    try testing.expectError(error.InvalidIndex, track.replace(3, notes[0]));
    try testing.expectError(error.InvalidIndex, track.remove(3));
    try testing.expectError(error.InvalidIndex, doc.removeTrack(1));

    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try doc.write(&writer, .{});
    try testing.expectEqualSlices(u8, fixture, writer.buffered());
}

test "same-time events, unknown meta, and SysEx fragments retain cursor order" {
    var buffer: [512]u8 = undefined;

    for ([_]bool{ true, false }) |running_status| {
        var writer = std.Io.Writer.fixed(&buffer);

        try smf.writeSource(.{}, rich_source, &writer, .{ .running_status = running_status });

        var doc = try document.Smf.parse(testing.allocator, writer.buffered());
        defer doc.deinit();
        try expectTrack(rich, doc.tracks.items[0].openCursor());
    }
}

test "owning documents retain format 2 independence and SMPTE timebase" {
    const header: smf.Header = .{
        .format = .sequential,
        .timing = .{
            .timecode = .{
                .frame_rate = .drop29,
                .ticks_per_frame = 80,
            },
        },
    };

    var doc = try document.Smf.fromSource(
        testing.allocator,
        header,
        smf.TimedSliceSource{ .items = &.{ rich, notes } },
    );
    defer doc.deinit();
    var output = std.Io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();
    try doc.write(&output.writer, .{});

    var restored = try document.Smf.parse(testing.allocator, output.written());
    defer restored.deinit();
    try testing.expectEqualDeep(header, restored.header);
    try testing.expectEqual(@as(usize, 2), restored.trackCount());
    try expectTrack(rich, restored.tracks.items[0].openCursor());
    try expectTrack(notes, restored.tracks.items[1].openCursor());
}

// Produces SMF events on demand without an event array.
const Generated = struct {
    pub fn trackCount(_: Generated) usize {
        return 1;
    }

    pub fn openTracks(_: Generated) Tracks {
        return .{};
    }

    const Tracks = struct {
        done: bool = false,
        pub fn next(self: *Tracks) error{}!?Track {
            if (self.done)
                return null;
            self.done = true;

            return .{};
        }
    };

    const Track = struct {
        pub fn openCursor(_: Track) Cursor {
            return .{};
        }
    };

    const Cursor = struct {
        position: u64 = 0,
        pub fn next(self: *Cursor) error{}!?smf.TimedEvent {
            if (self.position == 22)
                return null;
            const i = self.position;
            self.position += 1;

            return .{ .tick = i * 0xfffffff, .event = if (i == 21) end else on };
        }
    };
};

test "generated cursor writes timelines longer than u32 without flattening" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try smf.writeSource(.{}, Generated{}, &writer, .{});

    const file = try smf.File.parse(writer.buffered());
    var tracks = file.openTracks();
    var cursor = (try tracks.next()).?.openCursor();
    var expected = Generated.Cursor{};

    while (try expected.next()) |event| {
        try testing.expectEqualDeep(event, (try cursor.next()).?);
    }

    try testing.expectEqual(null, try cursor.next());
    try testing.expectEqual(@as(u64, 21) * 0xfffffff, cursor.tick);
}

test "absolute iterator checks overflow and leaves its state unchanged on failure" {
    var cursor = (smf.Track{ .data = "\x01\xff\x2f\x00" }).openCursor();
    cursor.tick = std.math.maxInt(u64);
    try testing.expectError(error.TimeOverflow, cursor.next());
    try testing.expectEqual(@as(usize, 0), cursor.inner.cursor.position);
    try testing.expectEqual(std.math.maxInt(u64), cursor.tick);
    try testing.expectError(error.TimeOverflow, cursor.next());
}

test "invalid timelines and later tracks fail before output" {
    const cases = .{
        .{
            @as(
                []const smf.TimedEvent,
                &.{
                    .{ .tick = 10, .event = on },
                    .{ .tick = 9, .event = end },
                },
            ),
            error.UnorderedEvents,
        },
        .{
            @as(
                []const smf.TimedEvent,
                &.{.{ .tick = 0x10000000, .event = end }},
            ),
            error.DeltaTooLarge,
        },
        .{ @as([]const smf.TimedEvent, &.{.{ .tick = 0, .event = on }}), error.MissingEndOfTrack },
        .{
            @as(
                []const smf.TimedEvent,
                &.{
                    .{ .tick = 0, .event = end },
                    .{ .tick = 0, .event = on },
                },
            ),
            error.DataAfterEndOfTrack,
        },
        .{
            @as(
                []const smf.TimedEvent,
                &.{
                    .{
                        .tick = 0,
                        .event = .{
                            .meta = .{ .kind = 0x51, .data = "bad-size" },
                        },
                    },
                },
            ),
            error.InvalidMetaEvent,
        },
    };

    inline for (cases) |case| {
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);

        try testing.expectError(
            case[1],
            smf.writeSource(
                .{ .format = .simultaneous },
                smf.TimedSliceSource{ .items = &.{ notes, case[0] } },
                &writer,
                .{},
            ),
        );
        try testing.expectEqual(@as(usize, 0), writer.end);
        try testing.expectError(
            case[1],
            document.Smf.fromSource(
                testing.allocator,
                .{},
                smf.TimedSliceSource{ .items = &.{case[0]} },
            ),
        );
    }
}

const BadSource = struct {
    declared: usize,
    actual: usize,
    fail: bool = false,
    pub fn trackCount(self: BadSource) usize {
        return self.declared;
    }

    pub fn openTracks(self: BadSource) Tracks {
        return .{ .remaining = self.actual, .fail = self.fail };
    }

    const Tracks = struct {
        remaining: usize,
        fail: bool,
        pub fn next(self: *Tracks) error{SourceFailure}!?sequence.Slice(smf.TimedEvent) {
            if (self.fail)
                return error.SourceFailure;
            if (self.remaining == 0)
                return null;
            self.remaining -= 1;

            return .{ .items = notes };
        }
    };
};

test "source track count mismatches and traversal errors propagate before output" {
    const cases = .{
        .{ BadSource{ .declared = 1, .actual = 2 }, error.InvalidTrackCount },
        .{ BadSource{ .declared = 2, .actual = 1 }, error.InvalidTrackCount },
        .{ BadSource{ .declared = 0, .actual = 0 }, error.InvalidTrackCount },
        .{ BadSource{ .declared = 1, .actual = 1, .fail = true }, error.SourceFailure },
    };

    inline for (cases) |case| {
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);

        try testing.expectError(
            case[1],
            smf.writeSource(
                .{ .format = .simultaneous },
                case[0],
                &writer,
                .{},
            ),
        );
        try testing.expectEqual(@as(usize, 0), writer.end);
        try testing.expectError(
            case[1],
            document.Smf.fromSource(
                testing.allocator,
                .{ .format = .simultaneous },
                case[0],
            ),
        );
    }
}

test "owning UMP preserves every raw family and full MIDI 2 precision" {
    var packets: [17]ump.Packet = undefined;

    for (0..16) |index| {
        packets[index] = .{
            .words = .{
                (@as(u32, @intCast(index)) << 28) | 0x0abcdef1,
                0x23456789,
                0xdeadbeef,
                0x87654321,
            },
        };
    }

    packets[16] = ump.Packet.fromMidi2(
        .{
            .group = 15,
            .channel = 14,
            .message = .{
                .control_change = .{ .controller = 74, .value = 0x12345678 },
            },
        },
    );
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    const packet_source: sequence.Slice(ump.Packet) = .{ .items = &packets };

    try ump.writeSource(packet_source, &writer);

    const length = writer.end;
    var expected: [256]u8 = bytes;
    var doc = try document.Ump.parse(testing.allocator, writer.buffered());
    defer doc.deinit();
    @memset(&bytes, 0);

    var cloned = try doc.clone(testing.allocator);
    defer cloned.deinit();
    doc.packets.items[0].words[0] = 0;
    writer = std.Io.Writer.fixed(&bytes);
    try cloned.write(&writer);
    try testing.expectEqualSlices(u8, expected[0..length], writer.buffered());
    try testing.expectEqual(
        @as(u32, 0x12345678),
        (try cloned.packets.items[16].asMidi2()).message.control_change.value,
    );
    var words = [_]u32{ 0x40903c00, 0x80001234, 0x60000001 };
    var native = try document.Ump.fromWords(testing.allocator, &words);
    defer native.deinit();
    words[1] = 0;
    try testing.expectEqual(@as(u32, 0x80001234), native.packets.items[0].words[1]);
    try testing.expectEqual(@as(usize, 2), native.packets.items.len);
}

test "UMP truncated source is rejected before output and partial import is freed" {
    const bytes = "\x00\x00\x00\x00\x40\x90\x3c\x00";
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try testing.expectError(
        error.UnexpectedEnd,
        ump.writeSource(
            ump.ByteSource{ .bytes = bytes },
            &writer,
        ),
    );
    try testing.expectEqual(@as(usize, 0), writer.end);
    try testing.expectError(error.UnexpectedEnd, document.Ump.parse(testing.allocator, bytes));
    try testing.expectError(
        error.UnexpectedEnd,
        document.Smf.parse(
            testing.allocator,
            fixture[0 .. fixture.len - 1],
        ),
    );
}

test "source writers propagate output failure" {
    var buffer: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try testing.expectError(error.WriteFailed, smf.writeSource(.{}, source, &writer, .{}));
    writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(
        error.WriteFailed,
        ump.writeSource(
            ump.WordSource{ .words = &.{0} },
            &writer,
        ),
    );
}

fn smfAllocations(allocator: std.mem.Allocator) !void {
    var doc = try document.Smf.fromSource(allocator, .{}, rich_source);
    defer doc.deinit();
    var cloned = try doc.clone(allocator);
    defer cloned.deinit();
    const track = &cloned.tracks.items[0];

    try track.insert(0, rich[1]);
    try track.replace(0, rich[2]);
    try track.remove(0);
    _ = try cloned.addTrack();
    try cloned.removeTrack(1);
    try cloned.validate();
}

fn umpAllocations(allocator: std.mem.Allocator) !void {
    var doc = try document.Ump.fromWords(allocator, &.{ 0x40903c00, 0x80001234, 0x60000001 });
    defer doc.deinit();
    var cloned = try doc.clone(allocator);
    defer cloned.deinit();
    try cloned.append(.{ .words = .{ 0, 0, 0, 0 } });
}

test "owning imports clones and edits clean up at every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, smfAllocations, .{});
    try testing.checkAllAllocationFailures(testing.allocator, umpAllocations, .{});
}

test "clone preserves incomplete documents without export validation" {
    var doc = document.Smf.init(testing.allocator, .{});
    defer doc.deinit();
    var empty = try doc.clone(testing.allocator);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.trackCount());

    const index = try doc.addTrack();

    try doc.tracks.items[index].append(.{ .tick = 10, .event = on });
    try doc.tracks.items[index].append(.{ .tick = 0, .event = on });

    var cloned = try doc.clone(testing.allocator);
    defer cloned.deinit();
    try testing.expectEqualDeep(
        doc.tracks.items[0].events.items,
        cloned.tracks.items[0].events.items,
    );
    try testing.expectError(error.UnorderedEvents, cloned.validate());
}

// Keep the load/edit/save example executable as part of the public API tests.
fn soften(bytes: []const u8, allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var doc = try document.Smf.parse(allocator, bytes);
    defer doc.deinit();

    for (doc.tracks.items) |*track| {
        for (track.events.items) |*event| {
            switch (event.event) {
                .midi => |*channel| switch (channel.message) {
                    .note_on => |*note| {
                        if (note.velocity != 0) {
                            note.velocity = @max(1, note.velocity / 2);
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
    }

    try doc.write(writer, .{});
}

test "documented load edit save example changes note velocity" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try soften(fixture, testing.allocator, &writer);

    var doc = try document.Smf.parse(testing.allocator, writer.buffered());
    defer doc.deinit();
    try testing.expectEqual(
        @as(u7, 50),
        doc.tracks.items[0].events.items[0].event.midi.message.note_on.velocity,
    );
    try testing.expectEqual(@as(u64, 480), doc.tracks.items[0].events.items[1].tick);
}
