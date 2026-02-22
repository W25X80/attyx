const std = @import("std");

/// A single cell in the terminal grid.
/// For now, stores just an ASCII character byte.
/// Will grow to include color/style attributes in later milestones.
pub const Cell = struct {
    char: u8 = ' ',
};

/// Fixed-size 2D grid of cells, stored as a flat row-major array.
/// One allocation on init, freed on deinit. No per-character allocations.
pub const Grid = struct {
    rows: usize,
    cols: usize,
    cells: []Cell,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Grid {
        std.debug.assert(rows > 0 and cols > 0);
        const cells = try allocator.alloc(Cell, rows * cols);
        @memset(cells, Cell{});
        return .{
            .rows = rows,
            .cols = cols,
            .cells = cells,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.cells);
    }

    pub fn getCell(self: *const Grid, row: usize, col: usize) Cell {
        return self.cells[row * self.cols + col];
    }

    pub fn setCell(self: *Grid, row: usize, col: usize, cell: Cell) void {
        self.cells[row * self.cols + col] = cell;
    }

    /// Reset every cell in the given row to default (space).
    pub fn clearRow(self: *Grid, row: usize) void {
        const start = row * self.cols;
        @memset(self.cells[start .. start + self.cols], Cell{});
    }

    /// Shift all rows up by one: row 1 becomes row 0, row 2 becomes row 1, etc.
    /// The bottom row is cleared. The old top row is lost.
    pub fn scrollUp(self: *Grid) void {
        const stride = self.cols;
        std.mem.copyForwards(
            Cell,
            self.cells[0 .. (self.rows - 1) * stride],
            self.cells[stride .. self.rows * stride],
        );
        self.clearRow(self.rows - 1);
    }
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "init creates grid filled with spaces" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 3, 4);
    defer g.deinit();

    for (0..3) |r| {
        for (0..4) |c| {
            try std.testing.expectEqual(@as(u8, ' '), g.getCell(r, c).char);
        }
    }
}

test "setCell and getCell round-trip" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 2, 2);
    defer g.deinit();

    g.setCell(0, 1, .{ .char = 'X' });
    try std.testing.expectEqual(@as(u8, 'X'), g.getCell(0, 1).char);
    try std.testing.expectEqual(@as(u8, ' '), g.getCell(0, 0).char);
}

test "clearRow resets row to spaces" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 2, 3);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(0, 1, .{ .char = 'B' });
    g.clearRow(0);

    try std.testing.expectEqual(@as(u8, ' '), g.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u8, ' '), g.getCell(0, 1).char);
}

test "scrollUp shifts rows and clears bottom" {
    const alloc = std.testing.allocator;
    var g = try Grid.init(alloc, 3, 2);
    defer g.deinit();

    g.setCell(0, 0, .{ .char = 'A' });
    g.setCell(1, 0, .{ .char = 'B' });
    g.setCell(2, 0, .{ .char = 'C' });
    g.scrollUp();

    try std.testing.expectEqual(@as(u8, 'B'), g.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u8, 'C'), g.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u8, ' '), g.getCell(2, 0).char);
}
