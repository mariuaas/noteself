//! Tick positions and borrowed slice iteration.

/// Absolute, nonnegative ticks in a timebase supplied by the enclosing sequence.
/// Equal ticks retain cursor order. Payload ownership follows Value's contract.
pub fn Timed(comptime Value: type) type {
    return struct {
        tick: u64,
        event: Value,
    };
}

/// A borrowed, repeatable source. Keep items and their payloads alive and unchanged
/// throughout every traversal. A cursor returns values, not pointers into storage.
pub fn Slice(comptime Value: type) type {
    return struct {
        items: []const Value,

        pub fn openCursor(self: @This()) Cursor {
            return .{ .items = self.items };
        }

        pub const Cursor = struct {
            items: []const Value,
            position: usize = 0,

            pub fn next(self: *Cursor) error{}!?Value {
                if (self.position == self.items.len)
                    return null;
                const value = self.items[self.position];
                self.position += 1;

                return value;
            }
        };
    };
}
