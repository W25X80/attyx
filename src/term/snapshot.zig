const std = @import("std");
const grid_mod = @import("grid.zig");

/// Serialize the grid to a plain-text string for golden-test comparison.
///
/// Format: exactly `rows` lines, each exactly `cols` characters wide
/// (trailing spaces preserved, not trimmed), terminated by '\n'.
/// Total length is always `rows * (cols + 1)` bytes.
///
/// Caller owns the returned slice and must free it with `allocator`.
pub fn dumpToString(allocator: std.mem.Allocator, grid: *const grid_mod.Grid) ![]u8 {
    const len = grid.rows * (grid.cols + 1);
    const buf = try allocator.alloc(u8, len);

    var pos: usize = 0;
    for (0..grid.rows) |row| {
        for (0..grid.cols) |col| {
            buf[pos] = grid.getCell(row, col).char;
            pos += 1;
        }
        buf[pos] = '\n';
        pos += 1;
    }

    return buf;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "snapshot of empty grid is all spaces" {
    const alloc = std.testing.allocator;
    var g = try grid_mod.Grid.init(alloc, 2, 3);
    defer g.deinit();

    const snap = try dumpToString(alloc, &g);
    defer alloc.free(snap);

    try std.testing.expectEqualStrings("   \n   \n", snap);
}

test "snapshot preserves content and trailing spaces" {
    const alloc = std.testing.allocator;
    var g = try grid_mod.Grid.init(alloc, 2, 4);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'H' });
    g.setCell(0, 1, .{ .char = 'i' });

    const snap = try dumpToString(alloc, &g);
    defer alloc.free(snap);

    try std.testing.expectEqualStrings("Hi  \n    \n", snap);
}
