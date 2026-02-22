const std = @import("std");
const runner = @import("runner.zig");

/// Helper: create a terminal, feed input, compare snapshot to expected output.
fn expectSnapshot(rows: usize, cols: usize, input: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const snap = try runner.run(alloc, rows, cols, input);
    defer alloc.free(snap);
    try std.testing.expectEqualStrings(expected, snap);
}

/// Helper: feed input as separate chunks, compare snapshot.
fn expectChunkedSnapshot(rows: usize, cols: usize, chunks: []const []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const snap = try runner.runChunked(alloc, rows, cols, chunks);
    defer alloc.free(snap);
    try std.testing.expectEqualStrings(expected, snap);
}

// ===========================================================================
// Basic printing (unchanged from milestone 1)
// ===========================================================================

test "golden: basic printing" {
    try expectSnapshot(3, 5, "Hello",
        "Hello\n" ++
        "     \n" ++
        "     \n");
}

test "golden: multiple characters fill left to right" {
    try expectSnapshot(2, 4, "ABCD",
        "ABCD\n" ++
        "    \n");
}

// ===========================================================================
// Line wrapping (unchanged)
// ===========================================================================

test "golden: text wraps at right edge" {
    try expectSnapshot(2, 3, "ABCDE",
        "ABC\n" ++
        "DE \n");
}

test "golden: wrap triggers scroll when grid is full" {
    try expectSnapshot(2, 3, "ABCDEF",
        "DEF\n" ++
        "   \n");
}

// ===========================================================================
// LF / CR (unchanged)
// ===========================================================================

test "golden: LF moves down, preserves column" {
    try expectSnapshot(3, 3, "A\nB",
        "A  \n" ++
        " B \n" ++
        "   \n");
}

test "golden: CR returns to column 0" {
    try expectSnapshot(2, 4, "AB\rC",
        "CB  \n" ++
        "    \n");
}

test "golden: CR LF together makes a traditional newline" {
    try expectSnapshot(3, 4, "AB\r\nCD",
        "AB  \n" ++
        "CD  \n" ++
        "    \n");
}

// ===========================================================================
// Backspace (unchanged)
// ===========================================================================

test "golden: backspace moves cursor left without erasing" {
    try expectSnapshot(2, 4, "AB\x08C",
        "AC  \n" ++
        "    \n");
}

test "golden: backspace clamps at column 0" {
    try expectSnapshot(2, 4, "\x08A",
        "A   \n" ++
        "    \n");
}

// ===========================================================================
// TAB (unchanged)
// ===========================================================================

test "golden: tab advances to next 8-column stop" {
    try expectSnapshot(2, 16, "A\tB",
        "A       B       \n" ++
        "                \n");
}

test "golden: tab clamps at last column" {
    try expectSnapshot(2, 8, "AAAAAAA\tB",
        "AAAAAAAB\n" ++
        "        \n");
}

// ===========================================================================
// Scrolling (unchanged)
// ===========================================================================

test "golden: scroll drops top row when LF at bottom" {
    try expectSnapshot(3, 4, "AAA\r\nBBB\r\nCCC\r\nDDD",
        "BBB \n" ++
        "CCC \n" ++
        "DDD \n");
}

test "golden: multiple scrolls" {
    try expectSnapshot(2, 3, "AB\r\nCD\r\nEF",
        "CD \n" ++
        "EF \n");
}

// ===========================================================================
// Escape sequence handling (NEW in milestone 2)
// ===========================================================================

test "golden: ESC consumes the following byte as escape sequence" {
    // ESC + B is a two-byte escape sequence — both bytes are consumed,
    // only 'A' before and 'C' after appear on screen.
    try expectSnapshot(2, 4, "A\x1bBC",
        "AC  \n" ++
        "    \n");
}

test "golden: CSI sequence is ignored, text after prints normally" {
    try expectSnapshot(2, 10, "\x1b[2JHello",
        "Hello     \n" ++
        "          \n");
}

test "golden: CSI with params is ignored" {
    // ESC[31m is "set foreground red" — ignored for now
    try expectSnapshot(2, 10, "\x1b[31mHello",
        "Hello     \n" ++
        "          \n");
}

test "golden: multiple CSI sequences ignored, text preserved" {
    try expectSnapshot(1, 12, "\x1b[1m\x1b[31mHello\x1b[0m!",
        "Hello!      \n");
}

test "golden: ESC non-bracket is ignored" {
    // ESC X is an unknown escape — just ignored, Hello prints fine
    try expectSnapshot(2, 10, "\x1bXHello",
        "Hello     \n" ++
        "          \n");
}

// ===========================================================================
// Incremental parsing across chunk boundaries (NEW in milestone 2)
// ===========================================================================

test "golden: ESC split across chunks" {
    // ESC arrives in one chunk, "[2J" in the next, then text
    try expectChunkedSnapshot(2, 10, &.{ "\x1b", "[2J", "Hello" },
        "Hello     \n" ++
        "          \n");
}

test "golden: CSI params split across chunks" {
    // ESC[31 in first chunk, "mHello" in second — 'm' completes the CSI
    try expectChunkedSnapshot(2, 10, &.{ "\x1b[31", "mHello" },
        "Hello     \n" ++
        "          \n");
}

test "golden: text interleaved with split CSI" {
    // "AB" then ESC[ then "1mCD" — AB prints, CSI is ignored, CD prints
    try expectChunkedSnapshot(2, 10, &.{ "AB\x1b[", "1mCD" },
        "ABCD      \n" ++
        "          \n");
}

test "golden: single-byte-at-a-time feeding" {
    // Feed every byte individually — worst-case chunking
    try expectChunkedSnapshot(1, 5, &.{ "\x1b", "[", "3", "1", "m", "H", "i" },
        "Hi   \n");
}
