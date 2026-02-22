//! Attyx — a deterministic VT-compatible terminal state machine.
//!
//! This is the library root. It re-exports the core types so consumers
//! can write `const attyx = @import("attyx");` and reach everything.

pub const actions = @import("term/actions.zig");
pub const grid = @import("term/grid.zig");
pub const parser = @import("term/parser.zig");
pub const state = @import("term/state.zig");
pub const snapshot = @import("term/snapshot.zig");
pub const engine = @import("term/engine.zig");

pub const Action = actions.Action;
pub const ControlCode = actions.ControlCode;
pub const Cell = grid.Cell;
pub const Grid = grid.Grid;
pub const Parser = parser.Parser;
pub const TerminalState = state.TerminalState;
pub const Cursor = state.Cursor;
pub const Engine = engine.Engine;

test {
    _ = @import("term/actions.zig");
    _ = @import("term/grid.zig");
    _ = @import("term/parser.zig");
    _ = @import("term/state.zig");
    _ = @import("term/snapshot.zig");
    _ = @import("term/engine.zig");
    _ = @import("headless/runner.zig");
    _ = @import("headless/tests.zig");
}
