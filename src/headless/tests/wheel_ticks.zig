//! Tests for the wheel delta -> tick conversion used by the macOS platform
//! layer (docs/wheel-sgr-accumulation-fix-design.md).
//!
//! Mirrors src/app/wheel_ticks.h (attyx_wheel_ticks) — keep in sync.
//! Scoped to in-range inputs; the helper's ±512-tick clamp keeps both
//! sides inside that range by construction.

const std = @import("std");

const wheel = @cImport({
    @cInclude("wheel_ticks.h");
});

fn wheelTicks(accum: *f64, dy_in: f64, precise: bool, cell_h: f64) i32 {
    return wheel.attyx_wheel_ticks(
        accum,
        dy_in,
        @intFromBool(precise),
        cell_h,
    );
}

fn routedWheelTicks(
    state: *wheel.AttyxWheelState,
    dy: f64,
    precise: bool,
    cell_h: f64,
    owner: u64,
    context: u64,
    routed: bool,
) i32 {
    return wheel.attyx_wheel_ticks_routed(
        state,
        dy,
        @intFromBool(precise),
        cell_h,
        owner,
        context,
        @intFromBool(routed),
    );
}

test "precise: small deltas accumulate, tick only at cell boundary" {
    var accum: f64 = 0;
    var total: i32 = 0;
    // 10 events x 3px, cell 17: total travel 30px -> exactly 1 tick.
    for (0..10) |_| total += wheelTicks(&accum, 3.0, true, 17.0);
    try std.testing.expectEqual(@as(i32, 1), total);
    try std.testing.expectApproxEqAbs(@as(f64, 13.0), accum, 1e-9);
}

test "precise: momentum stream produces ticks proportional to travel, not events" {
    var accum: f64 = 0;
    var total: i32 = 0;
    // 100 events x 3px = 300px travel, cell 17 -> trunc(300/17) = 17 ticks.
    // The pre-fix code emitted 100 (one per event).
    for (0..100) |_| total += wheelTicks(&accum, 3.0, true, 17.0);
    try std.testing.expectEqual(@as(i32, 17), total);
}

test "precise: single large flick event emits multiple ticks" {
    var accum: f64 = 0;
    const ticks = wheelTicks(&accum, 90.0, true, 17.0);
    try std.testing.expectEqual(@as(i32, 5), ticks);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), accum, 1e-9);
}

test "precise: direction reversal consumes remainder before opposite ticks" {
    var accum: f64 = 0;
    try std.testing.expectEqual(@as(i32, 0), wheelTicks(&accum, 10.0, true, 17.0));
    try std.testing.expectEqual(@as(i32, 0), wheelTicks(&accum, 4.0, true, 17.0));
    // accum = 14; -20 -> -6/17 -> 0 ticks yet; then -12 -> -18/17 -> -1.
    try std.testing.expectEqual(@as(i32, 0), wheelTicks(&accum, -20.0, true, 17.0));
    try std.testing.expectEqual(@as(i32, -1), wheelTicks(&accum, -12.0, true, 17.0));
}

test "precise: zero cell height falls back to 16 (parity with macos_input.m)" {
    var accum: f64 = 0;
    const ticks = wheelTicks(&accum, 32.0, true, 0.0);
    try std.testing.expectEqual(@as(i32, 2), ticks);
}

test "discrete: magnitude passes through with min-one" {
    var accum: f64 = 0;
    try std.testing.expectEqual(@as(i32, 1), wheelTicks(&accum, 1.0, false, 17.0));
    try std.testing.expectEqual(@as(i32, 3), wheelTicks(&accum, 3.7, false, 17.0));
    try std.testing.expectEqual(@as(i32, -5), wheelTicks(&accum, -5.2, false, 17.0));
    try std.testing.expectEqual(@as(i32, 1), wheelTicks(&accum, 0.4, false, 17.0));
    try std.testing.expectEqual(@as(i32, -1), wheelTicks(&accum, -0.4, false, 17.0));
    // Discrete events must not touch the accumulator.
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), accum, 1e-9);
}

test "discrete: zero delta emits nothing (phantom tilt-tick bugfix)" {
    var accum: f64 = 0;
    // Pre-fix inline code mapped dy==0 to -1 via the min-one branch.
    try std.testing.expectEqual(@as(i32, 0), wheelTicks(&accum, 0.0, false, 17.0));
}

test "clamp: synthetic huge deltas cap at 512 ticks, no banked residue" {
    var accum: f64 = 0;
    // Precise: 3.4e10 px, cell 17 -> exactly 512 ticks, remainder 0.
    try std.testing.expectEqual(@as(i32, 512), wheelTicks(&accum, 3.4e10, true, 17.0));
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), accum, 1e-9);
    // The next ordinary event behaves normally (nothing banked).
    try std.testing.expectEqual(@as(i32, 0), wheelTicks(&accum, 3.0, true, 17.0));
    // Discrete: +-1e9 -> +-512.
    var a2: f64 = 0;
    try std.testing.expectEqual(@as(i32, 512), wheelTicks(&a2, 1.0e9, false, 17.0));
    try std.testing.expectEqual(@as(i32, -512), wheelTicks(&a2, -1.0e9, false, 17.0));
}

test "clamp: negative huge precise delta caps at -512 ticks, no banked residue" {
    var accum: f64 = 0;
    try std.testing.expectEqual(@as(i32, -512), wheelTicks(&accum, -3.4e10, true, 17.0));
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), accum, 1e-9);
    // Nothing banked: the next ordinary event is fractional again.
    try std.testing.expectEqual(@as(i32, 0), wheelTicks(&accum, -3.0, true, 17.0));
}

test "mixed stream: discrete events preserve the precise accumulator residue" {
    var accum: f64 = 0;
    // Bank a 14px residue (cell 17), then a discrete notch arrives.
    try std.testing.expectEqual(@as(i32, 0), wheelTicks(&accum, 14.0, true, 17.0));
    try std.testing.expectEqual(@as(i32, 2), wheelTicks(&accum, 2.0, false, 17.0));
    // Deliberate deviation from kitty (design doc): residue survives.
    try std.testing.expectApproxEqAbs(@as(f64, 14.0), accum, 1e-9);
    // 3px more completes the cell -> 1 tick.
    try std.testing.expectEqual(@as(i32, 1), wheelTicks(&accum, 3.0, true, 17.0));
}

test "popup route: deltas outside bounds never contaminate residual" {
    var state: wheel.AttyxWheelState = std.mem.zeroes(wheel.AttyxWheelState);
    try std.testing.expectEqual(
        @as(i32, 0),
        routedWheelTicks(&state, 10.0, true, 17.0, 1, 1, true),
    );
    try std.testing.expectEqual(
        @as(i32, 0),
        routedWheelTicks(&state, 8.5, true, 17.0, 1, 1, false),
    );
    try std.testing.expectEqual(
        @as(i32, 0),
        routedWheelTicks(&state, 7.0, true, 17.0, 1, 1, true),
    );
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), state.accum, 1e-9);
}

test "route state: residual never crosses recipient or mode boundaries" {
    var state: wheel.AttyxWheelState = std.mem.zeroes(wheel.AttyxWheelState);
    try std.testing.expectEqual(@as(i32, 0), routedWheelTicks(&state, 10.0, true, 17.0, 1, 1, true));
    try std.testing.expectEqual(@as(i32, 0), routedWheelTicks(&state, 7.0, true, 17.0, 2, 1, true));
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), state.accum, 1e-9);
    try std.testing.expectEqual(@as(i32, 0), routedWheelTicks(&state, 7.0, true, 17.0, 2, 2, true));
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), state.accum, 1e-9);
}

test "route state: cell-height changes discard incompatible residual" {
    var state: wheel.AttyxWheelState = std.mem.zeroes(wheel.AttyxWheelState);
    try std.testing.expectEqual(@as(i32, 0), routedWheelTicks(&state, 16.0, true, 17.0, 1, 1, true));
    try std.testing.expectEqual(@as(i32, 0), routedWheelTicks(&state, 0.1, true, 8.0, 1, 1, true));
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), state.accum, 1e-9);
}

test "NaN delta is ignored and does not poison the accumulator" {
    var accum: f64 = 5.0;
    const nan = std.math.nan(f64);
    try std.testing.expectEqual(@as(i32, 0), wheelTicks(&accum, nan, true, 17.0));
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), accum, 1e-9);
    try std.testing.expectEqual(@as(i32, 0), wheelTicks(&accum, nan, false, 17.0));
}

test "parity sweep: helper equals the reference inline algorithm for dy != 0" {
    // Reference: transcription of the pre-fix macos_input.m:1080-1091 block.
    const Ref = struct {
        fn ticks(accum: *f64, dy: f64, precise: bool, cell_h: f64) i32 {
            if (precise) {
                accum.* += dy;
                const threshold: f64 = if (cell_h > 0) cell_h else 16.0;
                const lines = @as(i32, @intFromFloat(accum.* / threshold));
                accum.* -= @as(f64, @floatFromInt(lines)) * threshold;
                return lines;
            }
            var lines = @as(i32, @intFromFloat(dy));
            if (lines == 0) lines = if (dy > 0) 1 else -1;
            return lines;
        }
    };
    const deltas = [_]f64{ 1.0, -1.0, 2.5, -2.5, 3.0, 30.0, -18.0, 0.7, -0.7, 17.0, 34.5, -51.0 };
    const cells = [_]f64{ 8.0, 16.0, 17.0, 34.0 };
    for (cells) |cell| {
        inline for ([_]bool{ true, false }) |precise| {
            var a_new: f64 = 0;
            var a_ref: f64 = 0;
            for (deltas) |dy| {
                const t_new = wheelTicks(&a_new, dy, precise, cell);
                const t_ref = Ref.ticks(&a_ref, dy, precise, cell);
                try std.testing.expectEqual(t_ref, t_new);
                try std.testing.expectApproxEqAbs(a_ref, a_new, 1e-9);
            }
        }
    }
}
