# Noteself guide

[Back to the README](../README.md)

A modular MIDI 1.0, UMP, and MIDI 2.0 reader and writer for **Zig 0.16.0**, with storage-independent event traversal and optional owning documents. No dependencies, filesystem access, or platform MIDI backend. Codecs and traversal adapters do not allocate; owning documents use an explicitly supplied allocator.

## Modules

Import `noteself` for the common types, or use its public namespaces:

| Namespace | Purpose |
| --- | --- |
| `midi1` (`midi` alias) | MIDI 1.0 channel messages and byte encoding |
| `midi2` | All 15 defined MIDI 2.0 Channel Voice message opcodes |
| `ump` | Packet framing, byte/word iterators, Utility, System, MIDI 1.0/2.0, and SysEx7/8 fragments |
| `smf` | Standard MIDI File headers, timing, tracks, events, parsing, and writing |
| `live` | Complete MIDI wire packets, including system common and real-time messages |
| `sequence` | Absolute tick positions and borrowed slice cursors |
| `document` | Optional owning SMF documents and UMP packet sequences |

In the MIDI 1.0 codec, channel numbers are zero-based `u4` values. Keys, velocities, and other MIDI data use `u7`; pitch bend and song position use `u14`. Pitch bend is the raw unsigned value, with 8192 at the center. A note-on with velocity zero remains a note-on.

## Reading a MIDI file

```zig
const noteself = @import("noteself");

pub fn countNotes(bytes: []const u8) !usize {
    const file = try noteself.File.parse(bytes);
    var count: usize = 0;
    var tracks = file.tracks();

    while (try tracks.next()) |track| {
        var events = track.events();

        while (try events.next()) |event| {
            switch (event.kind) {
                .midi => |channel| switch (channel.message) {
                    .note_on => |note| {
                        if (note.velocity != 0) count += 1;
                    },
                    else => {},
                },
                else => {},
            }
        }
    }

    return count;
}
```

`File.parse` checks the header, chunk boundaries, and declared track count. Events are decoded lazily; call `try file.validate()` to check all of them without consuming your iterators. Iterating every track to completion also checks them. Each track must end with exactly one end-of-track meta event. A failed iterator call leaves its state unchanged.

Parsing borrows the original bytes. Keep the input alive and unchanged while using a file, track, iterator, or any event with a payload. Copying an event does not copy its meta or SysEx data. Track chunks and payloads are never allocated.

Formats 0, 1, and 2, metrical and SMPTE time divisions, running status, extended headers, and unknown chunks are supported. Unknown chunks are skipped, not retained for rewriting. Meta events retain their raw type and bytes, including unknown types. `meta.tempo()` returns microseconds per quarter note for a tempo event. Known fixed-size meta events are checked for their expected lengths; channel prefixes and nonzero tempo are also checked. Other meta payloads are left uninterpreted, including text encoding.

## Writing a MIDI file

```zig
const std = @import("std");
const noteself = @import("noteself");

pub fn writeNote(writer: *std.Io.Writer) !void {
    const track: []const noteself.Event = &.{
        .{ .kind = .{ .midi = .{
            .channel = 0,
            .message = .{ .note_on = .{ .key = 60, .velocity = 100 } },
        } } },
        .{ .delta = 480, .kind = .{ .midi = .{
            .channel = 0,
            .message = .{ .note_off = .{ .key = 60, .velocity = 64 } },
        } } },
        .{ .kind = .{ .meta = .end_of_track } },
    };

    try noteself.smf.write(.{
        .format = .single_track,
        .timing = .{ .metrical = 480 },
    }, &.{track}, writer, .{});
}
```

Pass any Zig 0.16 `std.Io.Writer`: a fixed buffer, an allocating writer with your allocator, a file writer, or your own implementation. For example:

```zig
var buffer: [1024]u8 = undefined;
var writer = std.Io.Writer.fixed(&buffer);

try writeNote(&writer);

const bytes = writer.buffered();
```

The writer validates all tracks before emitting the header. It counts encoded track sizes without allocation or seeking, then writes them to the supplied writer. Include an end-of-track event yourself. Running status is enabled by default; pass `.{ .running_status = false }` for explicit statuses throughout. Payloads must fit a 28-bit length and encoded tracks must fit a 32-bit length. Output errors propagate as `error.WriteFailed` and can leave partial output. Flush an underlying buffered output writer when you are ready; *the library does not flush it for you*.

In SMF events, `.sysex` omits the `0xf0` prefix and retains a terminating `0xf7` when present. `.escape` omits its `0xf7` prefix and preserves arbitrary bytes. These representations support split SysEx events.

## Owning documents

`document.Smf` owns its tracks and payloads, so you can release the input buffer after parsing. `document.Ump` owns its packet words. Both use an allocator you provide.

`sequence.Timed(Value)` is `{ tick: u64, event: Value }`: nonnegative **absolute** ticks in an explicitly supplied enclosing timebase. `smf.TimedEvent` uses `smf.Event.Kind` as its value and `smf.Header.timing` as its timebase. Format 2 tracks retain independent timelines. `Track.openCursor()` accumulates native SMF deltas into absolute ticks, with checked overflow. The original `Track.events()` and `smf.write()` delta-based APIs remain available and unchanged.

Equal-time events retain their supplied order. Noteself does not sort note-offs before note-ons, pair notes, normalize zero velocities, or merge tracks. End-of-track, tempo, unknown meta events, SysEx starts, and escape/continuation events remain explicit events. Byte-identical file reproduction is not promised: unknown chunks and extended header bytes are still skipped, and running status is chosen on export.

### Simple load, edit, save

```zig
pub fn soften(bytes: []const u8, allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var doc = try noteself.document.Smf.parse(allocator, bytes);
    defer doc.deinit();
    // The input bytes may now be released or reused. Every payload was copied.
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
```

`document.Smf.init(allocator, header)` creates an empty document. `addTrack()` returns an index into `tracks.items`; each track offers `append`, `insert`, `replace`, and `remove`. These methods keep the requested order. Payloads supplied to append/insert/replace are deep-copied. Use those methods when assigning new payloads; direct edits to ticks and value-only MIDI fields need no copying. Intermediate states may be invalid: call `validate()` or `write()` to check them. Include an end-of-track event and retain a valid header/track count before saving.

Payload allocations are stable until the track is destroyed. Removed or replaced payload storage remains in the track's arena until then; `clone(allocator)` makes an independent copy containing only the current events and payloads, including an incomplete document. `removeTrack(index)` destroys that track's storage. Documents and owning tracks must be moved, not shallow-copied; call `deinit()` once per owner. Growing arrays can invalidate pointers to elements. Reopen cursors after mutating a document. Failed insert/replace/append calls leave event contents unchanged, though internal capacity may have grown. Failed construction releases the partial document.

### Reading and writing sources

`smf.writeSource(header, source, writer, options)` accepts this structural Zig contract (no inheritance or runtime interface object is needed):

| Object | Methods |
| --- | --- |
| File source | `trackCount() usize`, `openTracks() TracksCursor` |
| Tracks cursor | `next() !?TrackSource` |
| Track source | `openCursor() EventCursor` |
| Event cursor | `next() !?smf.TimedEvent` |

Cursor factories are infallible; errors encountered during traversal come from `next()` and propagate to the caller. Each factory must open a fresh cursor over **the same unchanged content**. A track source must remain usable until the next tracks-cursor call; an event's borrowed payload must remain valid until the next event-cursor call. Copy or retain a payload if you need it beyond that lifetime. File-backed borrowed views retain their original, longer input-buffer lifetime.

The writer validates every track before emitting the file header, then reopens cursors to calculate lengths and encode events. It allocates nothing and does not flatten the source. Keep the source unchanged for the entire call. A source that changes between traversals violates the contract. Traversal failures during later passes and output failures can leave partial output. `smf.validateSource(header, source, options)` performs validation without output.

Both a parsed `smf.File` and an owning `document.Smf` implement this source contract. `smf.TimedSliceSource{ .items = tracks }` adapts `[]const []const smf.TimedEvent`. Individual gaps must fit SMF's `u28` delta encoding even though total absolute time is `u64`; unordered events, excessive gaps, invalid metadata, and missing end-of-track events are errors, not silently repaired. `smf.DeltaCursor(Cursor)` exposes the same checked absolute-to-delta adapter separately; discard and reopen it after an error.

`document.Smf.fromSource(allocator, header, source)` copies a source into an owning document, validates it, and releases partial results on failure. `sequence.Slice(Value){ .items = values }` supplies a borrowed source with `openCursor()` for values stored in a slice.

## Live packets

```zig
const event = try noteself.live.Event.parse(&.{ 0x90, 60, 100 });

try event.write(writer);
```

`live.Event.parse` takes exactly one complete packet with an explicit status byte. Its `.sysex` payload excludes both `0xf0` and `0xf7` delimiters. Undefined statuses, truncated messages, trailing bytes, and status bytes inside data are rejected. This API is for packets already framed by the caller; it does not assemble a byte stream, apply live running status, or extract interleaved real-time messages.

## UMP and MIDI 2.0

These codecs follow the [UMP and MIDI 2.0 Protocol specification v1.1.2](https://midi.org/universal-midi-packet-ump-and-midi-2-0-protocol-specification). MIDI 1.0 byte streams and SMF remain separate codecs. Existing `midi`, `live`, `smf`, and root aliases retain their meaning; `midi1` is an explicit alias for `midi`. No automatic conversion, precision scaling, or note-on normalization occurs.

```zig
const event: noteself.midi2.ChannelEvent = .{
    .group = 2,
    .channel = 3,
    .message = .{ .note_on = .{
        .key = 60,
        .velocity = 0x8000,
        .attribute_type = 3,
        .attribute_data = 60 * 512, // Pitch attribute: Q7.9.
    } },
};

const packet = noteself.ump.Packet.fromMidi2(event);

try packet.write(writer);

const decoded = try packet.asMidi2();
_ = decoded;
```

MIDI 2.0 velocities are `u16`; pressure, controller values, and pitch bend are `u32`. Relative registered/assignable controller values are signed `i32`. Pitch bend is centered at `0x80000000`. A MIDI 2.0 note-on with velocity zero remains a sounding note-on, unlike MIDI 1.0 semantics. Note attributes retain raw type/data fields, including unfamiliar types. Per-note controller indexes are `u8`, whereas registered/assignable channel-controller bank/index fields are `u7`. Groups and channels are separately zero-based `u4` values.

`midi2.ChannelEvent.words()` returns two **numeric words**. Use `ump.Packet.parseWords()` / `ump.WordIterator` for native numeric `u32` buffers. `Packet.parse()`, `ump.Iterator`, and `Packet.write()` use big-endian byte serialization of each word. Do not reinterpret platform-native words as these bytes without accounting for byte order. Packet parsing requires exactly one packet; iterators accept concatenated packets and leave their position unchanged on failure. No codec allocates or performs I/O beyond the supplied writer.

Raw `Packet` framing handles all 16 message-type allocations, including reserved 32/64/96/128-bit packet sizes. It preserves active words verbatim, without claiming that their contents are semantically valid. `group()` returns null for Utility, Stream, and reserved message types. Raw framing therefore preserves Flex Data, Stream discovery/configuration, Mixed Data Set, and unknown packets too. Dedicated typed decoders for those families are not yet provided.

Use `Packet.asMidi1()`, `asMidi2()`, `asSystem()`, `asUtility()`, `asSysEx7()`, or `asSysEx8()` for typed interpretation. Wrong families and unsupported statuses produce explicit errors. Receivers ignore reserved fields in supported messages; re-encoding a typed value emits those fields as zero. Retain the raw packet when exact preservation matters. Constructors and types enforce field widths; they do not enforce every controller-specific semantic restriction or session rule.

`Packet.fromMidi1(group, event)` wraps a MIDI 1.0 channel event in UMP **without promoting it to MIDI 2.0**. `fromSystem(group, event)` accepts the system-common and real-time variants of `live.Event`. It rejects channel messages and SysEx. Utility constructors cover NOOP, JR Clock/Timestamp, Delta Clockstamp, and its ticks-per-quarter setting. These are message values, not a scheduling clock.

`ump.SysEx7` and `ump.SysEx8` encode/decode individual fragments with explicit complete/start/continuation/end forms. Their fixed arrays hold up to 6 and 13 payload bytes respectively; SysEx8's count also includes its stream ID. SysEx8 abort is represented explicitly with `abort = true` on an empty end fragment. Unused payload bytes are ignored on decode and zeroed on encode. These APIs do not reassemble messages or validate cross-packet sequencing/interleaving.

This is packet and message support, not a device negotiation stack. MIDI-CI, protocol negotiation, whole-message SysEx assembly, MIDI Clip Files, and MIDI 1.0/2.0 translation policies remain separate work. The SMF writer continues to accept MIDI 1.0 events only; passing MIDI 2.0 data requires a different file codec, not an implicit downgrade.

### Owning UMP packets

`document.Ump.parse(allocator, bytes)` and `fromWords(allocator, words)` copy packets into `packets.items`. Edit packet values directly or use `append(packet)`; `clone(allocator)` makes an independent copy, `write(writer)` serializes active packet words, and `deinit()` releases storage. Unknown families and reserved bits remain intact. Packet values contain their words inline and borrow no payloads.

`ump.ByteSource`, `ump.WordSource`, `document.Ump`, and `sequence.Slice(ump.Packet)` all expose `openCursor()` with `next() !?ump.Packet`. `ump.writeSource(source, writer)` validates traversal before output, then reopens the unchanged source and writes raw packets. `document.Ump.fromSource` copies packets from any of these sources. For a nonrepeatable live source, consume its cursor and call `Packet.write` yourself.

`ump.TimedPacket` is `sequence.Timed(ump.Packet)` for packets with timestamps in a caller-defined timebase. No clock is inferred from packet order or Utility messages. The owning packet document is deliberately untimed; its writer does not accept `TimedPacket` values or silently discard their timestamps. Encoding a timed UMP file still requires a dedicated container codec.

## Use as a dependency

Add a dependency with `zig fetch --save git+https://github.com/mariuaas/noteself.git`, then wire it into your build:

```zig
const noteself = b.dependency("noteself", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("noteself", noteself.module("noteself"));
```

## Development

Tests live in `tests/` and are wired through `build.zig`. The MIDI, UMP, and document suites import the public `noteself` module; the codec suite tests the private byte codec separately.

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build check
zig fmt --check build.zig src tests
```

Tests cover independent wire fixtures, round trips, running status, time divisions, chunk boundaries, malformed inputs, truncation, output errors, and deterministic random input. UMP tests also cover independent field fixtures for every MIDI 2.0 channel opcode, all packet lengths, reserved-type preservation, SysEx fragment counts/abort, group/channel addressing, native precision, and malformed packets. Document tests exercise generated cursors without event arrays, simultaneous-event ordering, absolute/delta limits, timebase preservation, deep ownership, source errors before output, and every allocation failure during owning imports and edits. The default build exposes the Zig module; no executable or native library is installed.

## Future language bindings

The core uses slices, tagged unions, narrow integers, and Zig errors. These are Zig API types, not a stable C ABI. A future adapter should expose `noteself_*` functions with `callconv(.c)`, opaque iterator handles, fixed-width `extern` records, pointer/length buffers, and explicit status codes. Allocation and buffer ownership must be documented at that boundary, with matching release functions for any memory the adapter owns.

Keep that adapter separate from the core and install a versioned C header with static/shared library build targets. Bindings for other languages can then use the same C ABI. There are no C exports or headers yet.

RIFF/RMID containers, MIDI Clip Files, device I/O, and playback are outside the current API.
