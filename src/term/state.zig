const std = @import("std");
const grid_mod = @import("grid.zig");
const actions_mod = @import("actions.zig");

pub const Grid = grid_mod.Grid;
pub const Cell = grid_mod.Cell;
pub const Action = actions_mod.Action;
pub const ControlCode = actions_mod.ControlCode;

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
};

pub const TerminalState = struct {
    grid: Grid,
    cursor: Cursor = .{},

    pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !TerminalState {
        return .{
            .grid = try Grid.init(allocator, rows, cols),
        };
    }

    pub fn deinit(self: *TerminalState) void {
        self.grid.deinit();
    }

    /// Apply a single Action to the terminal state.
    /// This is the ONLY way state changes — the parser produces Actions,
    /// and this method executes them.
    pub fn apply(self: *TerminalState, action: Action) void {
        switch (action) {
            .print => |byte| self.printChar(byte),
            .control => |code| switch (code) {
                .lf => self.lineFeed(),
                .cr => self.carriageReturn(),
                .bs => self.backspace(),
                .tab => self.tab(),
            },
            .nop => {},
        }
    }

    fn printChar(self: *TerminalState, char: u8) void {
        self.grid.setCell(self.cursor.row, self.cursor.col, .{ .char = char });
        self.cursor.col += 1;
        if (self.cursor.col >= self.grid.cols) {
            self.cursor.col = 0;
            self.cursorDown();
        }
    }

    fn lineFeed(self: *TerminalState) void {
        self.cursorDown();
    }

    fn carriageReturn(self: *TerminalState) void {
        self.cursor.col = 0;
    }

    fn backspace(self: *TerminalState) void {
        if (self.cursor.col > 0) {
            self.cursor.col -= 1;
        }
    }

    fn tab(self: *TerminalState) void {
        const next_stop = ((self.cursor.col / 8) + 1) * 8;
        self.cursor.col = @min(next_stop, self.grid.cols - 1);
    }

    fn cursorDown(self: *TerminalState) void {
        self.cursor.row += 1;
        if (self.cursor.row >= self.grid.rows) {
            self.grid.scrollUp();
            self.cursor.row = self.grid.rows - 1;
        }
    }
};

// ---------------------------------------------------------------------------
// Unit tests — these exercise apply() directly, no parser involved
// ---------------------------------------------------------------------------

test "apply print writes to grid and advances cursor" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    try std.testing.expectEqual(@as(u8, 'A'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 1), t.cursor.col);
}

test "apply control.bs clamps at column 0" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .control = .bs });
    try std.testing.expectEqual(@as(usize, 0), t.cursor.col);
}

test "apply control.cr resets column to 0" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .control = .cr });
    try std.testing.expectEqual(@as(usize, 0), t.cursor.col);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
}

test "apply control.lf moves down, preserves column" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 3, 4);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    t.apply(.{ .control = .lf });
    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 1), t.cursor.col);
}

test "apply control.tab advances to next 8-column stop" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 20);
    defer t.deinit();

    t.apply(.{ .control = .tab });
    try std.testing.expectEqual(@as(usize, 8), t.cursor.col);
    t.apply(.{ .control = .tab });
    try std.testing.expectEqual(@as(usize, 16), t.cursor.col);
}

test "apply nop has no effect" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'X' });
    const row_before = t.cursor.row;
    const col_before = t.cursor.col;
    t.apply(.{ .nop = {} });
    try std.testing.expectEqual(row_before, t.cursor.row);
    try std.testing.expectEqual(col_before, t.cursor.col);
    try std.testing.expectEqual(@as(u8, 'X'), t.grid.getCell(0, 0).char);
}
