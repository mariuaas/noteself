const std = @import("std");
const codec = @import("codec.zig");
const midi = @import("midi.zig");
const sequence = @import("sequence.zig");

pub const Format = enum(u16) {
    single_track,
    simultaneous,
    sequential,
};

pub const FrameRate = enum(i8) {
    fps24 = -24,
    fps25 = -25,
    drop29 = -29,
    fps30 = -30,
};

pub const Timing = union(enum) {
    metrical: u15,
    timecode: struct {
        frame_rate: FrameRate,
        ticks_per_frame: u8,
    },

    pub fn decode(value: u16) codec.ParseError!Timing {
        if (value & 0x8000 == 0) {
            if (value == 0)
                return error.InvalidTiming;

            return .{ .metrical = @intCast(value) };
        }

        const signed: i8 = @bitCast(@as(u8, @intCast(value >> 8)));
        const frame_rate = std.enums.fromInt(FrameRate, signed) orelse
            return error.InvalidTiming;
        const ticks: u8 = @truncate(value);
        if (ticks == 0)
            return error.InvalidTiming;

        return .{
            .timecode = .{
                .frame_rate = frame_rate,
                .ticks_per_frame = ticks,
            },
        };
    }

    pub fn encode(self: Timing) codec.ParseError!u16 {
        return switch (self) {
            .metrical => |ticks| if (ticks == 0) error.InvalidTiming else ticks,
            .timecode => |timing| result: {
                if (timing.ticks_per_frame == 0)
                    return error.InvalidTiming;

                const frame_rate: u8 = @bitCast(@intFromEnum(timing.frame_rate));

                break :result (@as(u16, frame_rate) << 8) | timing.ticks_per_frame;
            },
        };
    }
};

pub const Header = struct {
    format: Format = .single_track,
    timing: Timing = .{ .metrical = 480 },

    pub fn validate(
        self: Header,
        track_count: usize,
    ) codec.ParseError!void {
        if (track_count == 0 or track_count > std.math.maxInt(u16))
            return error.InvalidTrackCount;
        if (self.format == .single_track and track_count != 1)
            return error.InvalidTrackCount;
        _ = try self.timing.encode();
    }
};

pub const Meta = struct {
    kind: u7,
    data: []const u8,

    pub const end_of_track: Meta = .{ .kind = 0x2f, .data = &.{} };

    pub fn validate(self: Meta) codec.ParseError!void {
        const length: ?usize = switch (self.kind) {
            0x00 => if (self.data.len == 0) 0 else 2,
            0x20, 0x21 => 1,
            0x2f => 0,
            0x51 => 3,
            0x54 => 5,
            0x58 => 4,
            0x59 => 2,
            else => null,
        };

        if (length) |expected| {
            if (self.data.len != expected)
                return error.InvalidMetaEvent;
        }

        if (self.kind == 0x20 and self.data[0] > 15)
            return error.InvalidMetaEvent;
        if (self.kind == 0x51 and self.tempo().? == 0)
            return error.InvalidMetaEvent;
    }

    pub fn tempo(self: Meta) ?u24 {
        if (self.kind != 0x51 or self.data.len != 3)
            return null;

        return std.mem.readInt(u24, self.data[0..3], .big);
    }
};

pub const Event = struct {
    delta: u28 = 0,
    kind: Kind,

    pub const Kind = union(enum) {
        midi: midi.ChannelEvent,
        sysex: []const u8,
        escape: []const u8,
        meta: Meta,
    };
};

/// Native SMF event contents positioned in absolute ticks of Header.timing.
/// The cursor order disambiguates equal ticks; no note pairing or sorting occurs.
pub const TimedEvent = sequence.Timed(Event.Kind);
pub const TimelineError = error{
    TimeOverflow,
    UnorderedEvents,
    DeltaTooLarge,
};

pub const TimedEventIterator = struct {
    inner: EventIterator,
    tick: u64 = 0,

    pub fn next(self: *TimedEventIterator) (codec.ParseError || TimelineError)!?TimedEvent {
        var state = self.*;
        const event = try state.inner.next() orelse return null;
        state.tick = std.math.add(u64, state.tick, event.delta) catch return error.TimeOverflow;
        self.* = state;

        return .{ .tick = state.tick, .event = event.kind };
    }
};

/// Adapt an absolute-time cursor to the delta events accepted by the SMF codec.
/// The input cursor is consumed on error; discard it and reopen the source.
pub fn DeltaCursor(comptime Cursor: type) type {
    return struct {
        inner: Cursor,
        tick: u64 = 0,

        pub fn next(self: *@This()) !?Event {
            const event = try self.inner.next() orelse return null;
            if (event.tick < self.tick)
                return error.UnorderedEvents;
            const delta = std.math.cast(u28, event.tick - self.tick) orelse
                return error.DeltaTooLarge;
            self.tick = event.tick;

            return .{ .delta = delta, .kind = event.event };
        }
    };
}

pub const Track = struct {
    data: []const u8,

    pub fn events(self: Track) EventIterator {
        return .{ .cursor = .{ .bytes = self.data } };
    }

    pub fn openCursor(self: Track) TimedEventIterator {
        return .{ .inner = self.events() };
    }

    pub fn validate(self: Track) codec.ParseError!void {
        var iterator = self.events();

        while (try iterator.next()) |_| {}
    }
};

pub const EventIterator = struct {
    cursor: codec.Cursor,
    running_status: ?u8 = null,
    ended: bool = false,

    pub fn next(self: *EventIterator) codec.ParseError!?Event {
        var state = self.*;
        if (state.ended) {
            if (state.cursor.remaining().len != 0)
                return error.DataAfterEndOfTrack;

            return null;
        }

        if (state.cursor.remaining().len == 0)
            return error.MissingEndOfTrack;
        const delta = try state.cursor.variableLength();
        const first = state.cursor.remaining();
        if (first.len == 0)
            return error.UnexpectedEnd;
        const status = if (first[0] < 0x80)
            state.running_status orelse
                return error.MissingRunningStatus
        else
            try state.cursor.byte();
        const kind: Event.Kind = switch (status) {
            0x80...0xef => result: {
                state.running_status = status;

                break :result .{ .midi = .{
                    .channel = @truncate(status),
                    .message = try midi.Message.readData(status, &state.cursor),
                } };
            },
            0xf0, 0xf7 => result: {
                state.running_status = null;

                const data = try state.cursor.payload();

                break :result if (status == 0xf0)
                    .{ .sysex = data }
                else
                    .{ .escape = data };
            },
            0xff => result: {
                state.running_status = null;

                const meta: Meta = .{
                    .kind = try state.cursor.dataByte(),
                    .data = try state.cursor.payload(),
                };

                try meta.validate();
                state.ended = meta.kind == 0x2f;
                if (state.ended and state.cursor.remaining().len != 0)
                    return error.DataAfterEndOfTrack;

                break :result .{ .meta = meta };
            },
            else => return error.InvalidStatus,
        };

        self.* = state;

        return .{ .delta = delta, .kind = kind };
    }
};

pub const File = struct {
    header: Header,
    track_count: u16,
    data: []const u8,

    pub fn parse(bytes: []const u8) codec.ParseError!File {
        var cursor: codec.Cursor = .{ .bytes = bytes };
        if (!std.mem.eql(u8, try cursor.take(4), "MThd"))
            return error.InvalidHeader;
        const header_length = try cursor.int(u32);
        if (header_length < 6)
            return error.InvalidHeader;
        var header_cursor: codec.Cursor = .{
            .bytes = try cursor.take(header_length),
        };

        const format = std.enums.fromInt(
            Format,
            try header_cursor.int(u16),
        ) orelse return error.InvalidFormat;
        const track_count = try header_cursor.int(u16);
        const header: Header = .{
            .format = format,
            .timing = try Timing.decode(try header_cursor.int(u16)),
        };

        try header.validate(track_count);

        const data = cursor.remaining();
        var found: usize = 0;

        while (cursor.remaining().len != 0) {
            const chunk = try readChunk(&cursor);
            if (std.mem.eql(u8, chunk.id, "MTrk")) {
                found += 1;
            }

            if (std.mem.eql(u8, chunk.id, "MThd"))
                return error.InvalidChunk;
        }

        if (found != track_count)
            return error.InvalidTrackCount;

        return .{ .header = header, .track_count = track_count, .data = data };
    }

    pub fn tracks(self: File) TrackIterator {
        return .{ .cursor = .{ .bytes = self.data } };
    }

    pub fn trackCount(self: File) usize {
        return self.track_count;
    }

    pub fn openTracks(self: File) TrackIterator {
        return self.tracks();
    }

    pub fn validate(self: File) codec.ParseError!void {
        var iterator = self.tracks();

        while (try iterator.next()) |track| {
            try track.validate();
        }
    }
};

const Chunk = struct {
    id: []const u8,
    data: []const u8,
};

fn readChunk(cursor: *codec.Cursor) codec.ParseError!Chunk {
    const id = try cursor.take(4);
    const length = try cursor.int(u32);

    return .{ .id = id, .data = try cursor.take(length) };
}

pub const TrackIterator = struct {
    cursor: codec.Cursor,

    pub fn next(self: *TrackIterator) codec.ParseError!?Track {
        var cursor = self.cursor;

        while (cursor.remaining().len != 0) {
            const chunk = try readChunk(&cursor);
            if (std.mem.eql(u8, chunk.id, "MTrk")) {
                self.cursor = cursor;

                return .{ .data = chunk.data };
            }
        }

        self.cursor = cursor;

        return null;
    }
};

pub const WriteOptions = struct { running_status: bool = true };
pub const WriteError = codec.ParseError || std.Io.Writer.Error || error{
    TrackTooLarge,
    PayloadTooLarge,
};

pub fn write(
    header: Header,
    tracks: []const []const Event,
    writer: *std.Io.Writer,
    options: WriteOptions,
) WriteError!void {
    try header.validate(tracks.len);

    for (tracks) |track| {
        _ = try trackSize(track, options);
    }

    try writeHeader(header, tracks.len, writer);

    for (tracks) |track| {
        const size = try trackSize(track, options);

        try writer.writeAll("MTrk");
        try codec.writeInt(writer, u32, size);
        try writeTrack(
            (sequence.Slice(Event){ .items = track }).openCursor(),
            writer,
            options,
        );
    }
}

fn trackSize(
    events: []const Event,
    options: WriteOptions,
) WriteError!u32 {
    var counter = std.Io.Writer.Discarding.init(&.{});

    try writeTrack(
        (sequence.Slice(Event){ .items = events }).openCursor(),
        &counter.writer,
        options,
    );

    return std.math.cast(u32, counter.fullCount()) orelse error.TrackTooLarge;
}

fn writePayload(writer: *std.Io.Writer, data: []const u8) WriteError!void {
    const length = std.math.cast(u28, data.len) orelse return error.PayloadTooLarge;

    try codec.writeVariableLength(writer, length);
    try writer.writeAll(data);
}

fn writeTrack(
    input: anytype,
    writer: *std.Io.Writer,
    options: WriteOptions,
) !void {
    var cursor = input;
    var running_status: ?u8 = null;
    var ended = false;

    while (try cursor.next()) |event| {
        if (ended)
            return error.DataAfterEndOfTrack;
        try codec.writeVariableLength(writer, event.delta);

        switch (event.kind) {
            .midi => |channel| {
                const status = channel.message.status(channel.channel);
                if (!options.running_status or running_status != status)
                    try writer.writeByte(status);
                try channel.message.writeData(writer);
                running_status = status;
            },
            .sysex, .escape => |data| {
                try writer.writeByte(if (event.kind == .sysex) 0xf0 else 0xf7);
                try writePayload(writer, data);
                running_status = null;
            },
            .meta => |meta| {
                try meta.validate();
                try writer.writeAll(&.{ 0xff, meta.kind });
                try writePayload(writer, meta.data);
                running_status = null;
                ended = meta.kind == 0x2f;
            },
        }
    }

    if (!ended)
        return error.MissingEndOfTrack;
}

fn writeHeader(
    header: Header,
    track_count: usize,
    writer: *std.Io.Writer,
) WriteError!void {
    try writer.writeAll("MThd");
    try codec.writeInt(writer, u32, 6);
    try codec.writeInt(writer, u16, @intFromEnum(header.format));
    try codec.writeInt(writer, u16, @intCast(track_count));
    try codec.writeInt(writer, u16, try header.timing.encode());
}

/// An adapter for arrays of absolute-time tracks. Storage and payloads are borrowed.
pub const TimedSliceSource = struct {
    items: []const []const TimedEvent,

    pub fn trackCount(self: TimedSliceSource) usize {
        return self.items.len;
    }

    pub fn openTracks(self: TimedSliceSource) Tracks {
        return .{ .items = self.items };
    }

    pub const Tracks = struct {
        items: []const []const TimedEvent,
        position: usize = 0,

        pub fn next(self: *Tracks) error{}!?sequence.Slice(TimedEvent) {
            if (self.position == self.items.len)
                return null;
            const items = self.items[self.position];
            self.position += 1;

            return .{ .items = items };
        }
    };
};

fn timedTrackSize(track: anytype, options: WriteOptions) !u32 {
    var counter = std.Io.Writer.Discarding.init(&.{});
    const cursor = track.openCursor();

    try writeTrack(DeltaCursor(@TypeOf(cursor)){ .inner = cursor }, &counter.writer, options);

    return std.math.cast(u32, counter.fullCount()) orelse error.TrackTooLarge;
}

/// Validate every event, time, and encoded size without allocation or output.
/// source: trackCount() usize, openTracks() -> cursor with next() !?TrackSource.
/// TrackSource: openCursor() -> cursor with next() !?TimedEvent.
/// Factories are infallible; traversal errors are returned by next().
pub fn validateSource(
    header: Header,
    source: anytype,
    options: WriteOptions,
) !void {
    const count = source.trackCount();

    try header.validate(count);

    var tracks = source.openTracks();

    for (0..count) |_| {
        const track = try tracks.next() orelse return error.InvalidTrackCount;
        _ = try timedTrackSize(track, options);
    }

    if (try tracks.next() != null)
        return error.InvalidTrackCount;
}

/// Write a repeatable absolute-time source, preserving equal-time cursor order.
/// All tracks are validated before output. The source must represent one unchanged
/// sequence across validation, size counting, and writing; each factory returns a
/// fresh cursor. Payloads need only remain valid until the next call to that cursor.
/// Source errors propagate; errors after output begins can leave partial output.
pub fn writeSource(
    header: Header,
    source: anytype,
    writer: *std.Io.Writer,
    options: WriteOptions,
) !void {
    try validateSource(header, source, options);

    const count = source.trackCount();

    try writeHeader(header, count, writer);

    var tracks = source.openTracks();

    for (0..count) |_| {
        const track = try tracks.next() orelse return error.InvalidTrackCount;
        const size = try timedTrackSize(track, options);

        try writer.writeAll("MTrk");
        try codec.writeInt(writer, u32, size);

        const cursor = track.openCursor();

        try writeTrack(
            DeltaCursor(@TypeOf(cursor)){ .inner = cursor },
            writer,
            options,
        );
    }

    if (try tracks.next() != null)
        return error.InvalidTrackCount;
}
