const std = @import("std");
const actions = @import("actions.zig");

pub const Action = actions.Action;
pub const ControlCode = actions.ControlCode;

/// Internal parser state — tracks where we are in escape sequence recognition.
///
///   Ground ──ESC──▸ Escape ──[──▸ Csi
///     ▲                │            │
///     └──── any ◂──────┘    final ──┘
///
const State = enum {
    /// Normal text processing.
    ground,
    /// Saw ESC (0x1B), waiting to see if '[' follows (CSI) or something else.
    escape,
    /// Inside a CSI sequence (ESC [), consuming parameter bytes until a
    /// final byte (0x40..0x7E) terminates the sequence.
    csi,
};

/// Incremental VT parser.
///
/// Consumes one byte at a time via `next()`, returning an optional Action.
/// Maintains internal state across calls so partial escape sequences that
/// span multiple `feed()` chunks are handled correctly.
///
/// Zero allocations — all state lives in fixed-size fields.
pub const Parser = struct {
    state: State = .ground,

    /// Buffer for CSI parameter/intermediate bytes (retained for debug tracing).
    /// Only `csi_buf[0..csi_len]` is valid after a CSI sequence completes.
    csi_buf: [64]u8 = undefined,
    csi_len: usize = 0,
    /// The final byte of the last completed CSI sequence (for tracing).
    csi_final: u8 = 0,
    /// The byte that followed ESC in the last non-CSI escape (for tracing).
    last_esc_byte: u8 = 0,

    /// Process a single byte. Returns an Action if one is ready,
    /// or null if the byte was consumed as part of an incomplete sequence.
    pub fn next(self: *Parser, byte: u8) ?Action {
        return switch (self.state) {
            .ground => self.onGround(byte),
            .escape => self.onEscape(byte),
            .csi => self.onCsi(byte),
        };
    }

    // -- State handlers ----------------------------------------------------

    fn onGround(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x1B => {
                self.state = .escape;
                return null;
            },
            0x20...0x7E => return .{ .print = byte },
            '\n' => return .{ .control = .lf },
            '\r' => return .{ .control = .cr },
            0x08 => return .{ .control = .bs },
            '\t' => return .{ .control = .tab },
            else => return .nop,
        }
    }

    fn onEscape(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            '[' => {
                self.state = .csi;
                self.csi_len = 0;
                return null;
            },
            0x1B => {
                // Another ESC cancels the first; stay in escape state.
                return .nop;
            },
            else => {
                self.last_esc_byte = byte;
                self.state = .ground;
                return .nop;
            },
        }
    }

    fn onCsi(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            // Final byte — terminates the CSI sequence.
            0x40...0x7E => {
                self.csi_final = byte;
                self.state = .ground;
                return .nop;
            },
            // ESC inside CSI cancels the current sequence and starts a new escape.
            0x1B => {
                self.state = .escape;
                return .nop;
            },
            // Parameter or intermediate byte — buffer it and keep consuming.
            else => {
                if (self.csi_len < self.csi_buf.len) {
                    self.csi_buf[self.csi_len] = byte;
                    self.csi_len += 1;
                }
                return null;
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "printable bytes produce print actions" {
    var p: Parser = .{};
    try std.testing.expectEqual(Action{ .print = 'A' }, p.next('A').?);
    try std.testing.expectEqual(Action{ .print = '~' }, p.next('~').?);
    try std.testing.expectEqual(Action{ .print = ' ' }, p.next(' ').?);
}

test "control codes produce control actions" {
    var p: Parser = .{};
    try std.testing.expectEqual(Action{ .control = .lf }, p.next('\n').?);
    try std.testing.expectEqual(Action{ .control = .cr }, p.next('\r').?);
    try std.testing.expectEqual(Action{ .control = .bs }, p.next(0x08).?);
    try std.testing.expectEqual(Action{ .control = .tab }, p.next('\t').?);
}

test "unknown bytes produce nop" {
    var p: Parser = .{};
    try std.testing.expectEqual(Action{ .nop = {} }, p.next(0x00).?);
    try std.testing.expectEqual(Action{ .nop = {} }, p.next(0x7F).?);
}

test "ESC enters escape state, no action emitted" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0x1B) == null);
}

test "ESC [ ... final produces nop (CSI ignored)" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0x1B) == null);
    try std.testing.expect(p.next('[') == null);
    try std.testing.expect(p.next('3') == null);
    try std.testing.expect(p.next('1') == null);
    try std.testing.expectEqual(Action{ .nop = {} }, p.next('m').?);
}

test "ESC followed by non-bracket emits nop and returns to ground" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0x1B) == null);
    try std.testing.expectEqual(Action{ .nop = {} }, p.next('X').?);
    // Back in ground — printable works
    try std.testing.expectEqual(Action{ .print = 'A' }, p.next('A').?);
}

test "ESC during escape cancels first, stays in escape" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    // Second ESC cancels the first
    try std.testing.expectEqual(Action{ .nop = {} }, p.next(0x1B).?);
    // Still in escape — [ should enter CSI
    try std.testing.expect(p.next('[') == null);
    try std.testing.expectEqual(Action{ .nop = {} }, p.next('m').?);
}

test "ESC during CSI cancels sequence, enters new escape" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('3');
    // ESC cancels the CSI
    try std.testing.expectEqual(Action{ .nop = {} }, p.next(0x1B).?);
    // Now in escape state — [ enters CSI again
    try std.testing.expect(p.next('[') == null);
    try std.testing.expectEqual(Action{ .nop = {} }, p.next('m').?);
}

test "CSI parameters are buffered for tracing" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('3');
    _ = p.next('1');
    _ = p.next(';');
    _ = p.next('1');
    _ = p.next('m');
    try std.testing.expectEqualStrings("31;1", p.csi_buf[0..p.csi_len]);
    try std.testing.expectEqual(@as(u8, 'm'), p.csi_final);
}

test "returns to ground after CSI final byte" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('m');
    try std.testing.expectEqual(Action{ .print = 'Z' }, p.next('Z').?);
}
