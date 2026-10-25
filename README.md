# noteself

A MIDI toolkit for **Zig 0.16.0**. Read and write `.mid` files, work with MIDI 1.0 messages, or dig into UMP and MIDI 2.0.
Essentially, this project was extracted / constructed as part of a set of personal projects I've been working on for a while.

Walk through events without allocating, load a document to edit, or bring your own storage. No dependencies, and you choose when to allocate.

## Getting started

Add the library with `zig fetch --save git+https://github.com/mariuaas/noteself.git`, then connect it to your build:

```zig
const noteself = b.dependency("noteself", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("noteself", noteself.module("noteself"));
```

Already have MIDI bytes in memory? Here's how to load a document and write it back using your allocator and writer:

```zig
const noteself = @import("noteself");

var song = try noteself.document.Smf.parse(allocator, bytes);
defer song.deinit();

try song.write(writer, .{});
```

You can edit the events in `song.tracks.items` before writing. For an example, see [load, edit, save](docs/guide.md#simple-load-edit-save).

The [guide](docs/guide.md) contains more details on necessary fidgetery: borrowed parsing, writing, ownership, custom event sources, and MIDI 2.0 packets. 
C bindings are planned; the current API is Zig.

## Working on it

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig fmt --check build.zig src tests
```

## Planned Stuff

At some point, I'm planning to add C headers as well as bindings for other languages, such as Python, Lua, Rust, and other languages I tend to use.

## Credit and shoutouts

Thanks to [midly](https://github.com/kovaxis/midly) for inspiration, especially its borrowed payloads and separation of file events from live messages.

*Disclaimer: the rewrite / extraction of this library was done with help with AI tools.*
