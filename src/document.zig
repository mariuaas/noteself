//! Owning SMF tracks and UMP packet sequences.

const std = @import("std");
const smf = @import("smf.zig");
const ump = @import("ump.zig");
const sequence = @import("sequence.zig");

/// Payloads copied through append/insert/replace remain stable until deinit.
/// Removed/replaced payload storage is retained in the arena until deinit;
/// cloning the document retains only its current events and payloads.
/// Do not shallow-copy owning tracks or documents. Moving ownership is allowed.
pub const SmfTrack = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(smf.TimedEvent) = .empty,
    payloads: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) SmfTrack {
        return .{
            .allocator = allocator,
            .payloads = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *SmfTrack) void {
        self.events.deinit(self.allocator);
        self.payloads.deinit();
        self.* = undefined;
    }

    pub fn openCursor(self: *const SmfTrack) sequence.Slice(smf.TimedEvent).Cursor {
        return (sequence.Slice(smf.TimedEvent){ .items = self.events.items }).openCursor();
    }

    fn own(self: *SmfTrack, event: smf.TimedEvent) std.mem.Allocator.Error!smf.TimedEvent {
        var result = event;
        const allocator = self.payloads.allocator();

        switch (event.event) {
            .midi => {},
            .meta => |meta| result.event.meta.data = try allocator.dupe(u8, meta.data),
            .sysex => |data| result.event.sysex = try allocator.dupe(u8, data),
            .escape => |data| result.event.escape = try allocator.dupe(u8, data),
        }

        return result;
    }

    /// Deep-copy the payload. Tick order and SMF validity are checked on export,
    /// so a track can be constructed before adding its end-of-track event.
    pub fn append(self: *SmfTrack, event: smf.TimedEvent) std.mem.Allocator.Error!void {
        try self.events.ensureUnusedCapacity(self.allocator, 1);

        const owned = try self.own(event);
        self.events.appendAssumeCapacity(owned);
    }

    pub fn insert(self: *SmfTrack, index: usize, event: smf.TimedEvent) !void {
        if (index > self.events.items.len)
            return error.InvalidIndex;
        try self.events.ensureUnusedCapacity(self.allocator, 1);

        const owned = try self.own(event);
        self.events.insertAssumeCapacity(index, owned);
    }

    pub fn replace(self: *SmfTrack, index: usize, event: smf.TimedEvent) !void {
        if (index >= self.events.items.len)
            return error.InvalidIndex;
        const owned = try self.own(event);
        self.events.items[index] = owned;
    }

    pub fn remove(self: *SmfTrack, index: usize) error{InvalidIndex}!void {
        if (index >= self.events.items.len)
            return error.InvalidIndex;
        _ = self.events.orderedRemove(index);
    }
};

/// Absolute-time SMF tracks. Header.timing supplies the tick units; format 2
/// tracks remain independent sequences. Import/export preserves event semantics,
/// not original running-status choices, extended headers, or unknown chunks.
pub const Smf = struct {
    allocator: std.mem.Allocator,
    header: smf.Header,
    tracks: std.ArrayList(SmfTrack) = .empty,

    pub fn init(allocator: std.mem.Allocator, header: smf.Header) Smf {
        return .{ .allocator = allocator, .header = header };
    }

    pub fn deinit(self: *Smf) void {
        for (self.tracks.items) |*track| {
            track.deinit();
        }

        self.tracks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Smf {
        const file = try smf.File.parse(bytes);

        return fromSource(allocator, file.header, file);
    }

    /// Import a source with the same contract as smf.writeSource. On any failure,
    /// release the partial document. No references to source storage are retained.
    pub fn fromSource(
        allocator: std.mem.Allocator,
        header: smf.Header,
        source: anytype,
    ) !Smf {
        const count = source.trackCount();

        try header.validate(count);

        var result = init(allocator, header);
        errdefer result.deinit();
        var tracks = source.openTracks();

        for (0..count) |_| {
            const track = try tracks.next() orelse return error.InvalidTrackCount;
            const index = try result.addTrack();
            var cursor = track.openCursor();

            while (try cursor.next()) |event| {
                try result.tracks.items[index].append(event);
            }
        }

        if (try tracks.next() != null)
            return error.InvalidTrackCount;
        try result.validate();

        return result;
    }

    /// Deep-copy the current tracks without requiring a valid header, ordered
    /// events, or an end-of-track event.
    pub fn clone(self: *const Smf, allocator: std.mem.Allocator) !Smf {
        var result = init(allocator, self.header);
        errdefer result.deinit();

        for (self.tracks.items) |*track| {
            const index = try result.addTrack();
            var cursor = track.openCursor();

            while (try cursor.next()) |event| {
                try result.tracks.items[index].append(event);
            }
        }

        return result;
    }

    /// Adding a track may invalidate pointers to tracks, but not their payloads.
    pub fn addTrack(self: *Smf) std.mem.Allocator.Error!usize {
        const index = self.tracks.items.len;

        try self.tracks.append(self.allocator, SmfTrack.init(self.allocator));

        return index;
    }

    pub fn removeTrack(self: *Smf, index: usize) error{InvalidIndex}!void {
        if (index >= self.tracks.items.len)
            return error.InvalidIndex;
        var track = self.tracks.orderedRemove(index);
        track.deinit();
    }

    pub fn trackCount(self: *const Smf) usize {
        return self.tracks.items.len;
    }

    pub fn openTracks(self: *const Smf) Tracks {
        return .{ .items = self.tracks.items };
    }

    pub const Tracks = struct {
        items: []const SmfTrack,
        position: usize = 0,

        pub fn next(self: *Tracks) error{}!?sequence.Slice(smf.TimedEvent) {
            if (self.position == self.items.len)
                return null;
            const track = &self.items[self.position];
            self.position += 1;

            return .{ .items = track.events.items };
        }
    };

    pub fn validate(self: *const Smf) !void {
        try smf.validateSource(self.header, self, .{});
    }

    pub fn write(
        self: *const Smf,
        writer: *std.Io.Writer,
        options: smf.WriteOptions,
    ) !void {
        try smf.writeSource(self.header, self, writer, options);
    }
};

/// An owning, editable packet sequence, without inferred timestamps. Every packet
/// stores its words inline, including unknown families and reserved bits.
pub const Ump = struct {
    allocator: std.mem.Allocator,
    packets: std.ArrayList(ump.Packet) = .empty,

    pub fn init(allocator: std.mem.Allocator) Ump {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Ump) void {
        self.packets.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Ump {
        return fromSource(allocator, ump.ByteSource{ .bytes = bytes });
    }

    pub fn fromWords(allocator: std.mem.Allocator, words: []const u32) !Ump {
        return fromSource(allocator, ump.WordSource{ .words = words });
    }

    pub fn fromSource(allocator: std.mem.Allocator, source: anytype) !Ump {
        var result = init(allocator);
        errdefer result.deinit();
        var cursor = source.openCursor();

        while (try cursor.next()) |packet| {
            try result.append(packet);
        }

        return result;
    }

    pub fn clone(self: *const Ump, allocator: std.mem.Allocator) !Ump {
        return fromSource(allocator, self);
    }

    pub fn append(self: *Ump, packet: ump.Packet) std.mem.Allocator.Error!void {
        try self.packets.append(self.allocator, packet);
    }

    pub fn openCursor(self: *const Ump) sequence.Slice(ump.Packet).Cursor {
        return (sequence.Slice(ump.Packet){ .items = self.packets.items }).openCursor();
    }

    pub fn write(self: *const Ump, writer: *std.Io.Writer) !void {
        try ump.writeSource(self, writer);
    }
};
