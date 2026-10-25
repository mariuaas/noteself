pub const sequence = @import("sequence.zig");
pub const document = @import("document.zig");

pub const midi1 = @import("midi.zig");
pub const midi2 = @import("midi2.zig");
pub const ump = @import("ump.zig");

// Existing MIDI 1.0 aliases remain source-compatible.
pub const midi = @import("midi.zig");
pub const smf = @import("smf.zig");
pub const live = @import("live.zig");

pub const Message = midi.Message;
pub const ChannelEvent = midi.ChannelEvent;
pub const File = smf.File;
pub const Header = smf.Header;
pub const Event = smf.Event;
pub const ParseError = @import("codec.zig").ParseError;
