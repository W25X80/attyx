# Wheel SGR Accumulation Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Emit SGR mouse-wheel ticks from accumulated scroll deltas (one tick per line of travel) instead of one tick per NSEvent (design: `docs/wheel-sgr-accumulation-fix-design.md`).

**Architecture:** Extract the already-correct accumulator into a pure `static inline` helper (`wheel_ticks.h`), use it in all three `scrollWheel:` paths with independent accumulators; batch-emit `|ticks|` SGR events. TDD with a Zig mirror test file.

**Tech stack:** Objective-C (AppKit), Zig 0.15.2 headless tests via `mise x zig@0.15.2 -- zig build test`.

## Global constraints

- Branch: `fix/wheel-scroll-accumulation` from `main`.
- Toolchain: system zig is 0.16 and cannot build the project; all gates via `mise x zig@0.15.2 -- ...`.
- Known pre-existing failure: `app.daemon.agent_status_test` timeout (flaky on untouched `main`). Gate = no NEW failures.
- New files stay under ~600 lines; `macos_input.m` (1114, grandfathered) grows by <10 lines net.
- Do not touch the untracked WIP files (`wheel_route.zig`, `mouse.zig`, blueprints).

---

### Task 0: Branch

- [ ] **Step 0.1:** `git checkout -b fix/wheel-scroll-accumulation main` (tracked tree is clean; untracked WIP carries over untouched).

### Task 1: Failing tests (RED)

**Files:** Create `src/headless/tests/wheel_ticks.zig`; modify `src/headless/tests.zig` (register after the `resize_scale_coherence` import — note: on `main` that import does not exist; register after `resize_rounding`).

- [ ] **Step 1.1:** Create the test file:

```zig
//! Tests for the wheel delta -> tick conversion used by the macOS platform
//! layer (docs/wheel-sgr-accumulation-fix-design.md).
//!
//! Mirrors src/app/wheel_ticks.h (attyx_wheel_ticks) — keep in sync.

const std = @import("std");

const max_ticks: f64 = 512.0; // mirrors ATTYX_WHEEL_MAX_TICKS

fn wheelTicks(accum: *f64, dy_in: f64, precise: bool, cell_h: f64) i32 {
    var dy = dy_in;
    if (precise) {
        accum.* += dy;
        const threshold: f64 = if (cell_h > 0) cell_h else 16.0;
        const limit = max_ticks * threshold;
        if (accum.* > limit) accum.* = limit;
        if (accum.* < -limit) accum.* = -limit;
        const ticks = @as(i32, @intFromFloat(accum.* / threshold));
        accum.* -= @as(f64, @floatFromInt(ticks)) * threshold;
        return ticks;
    }
    if (dy == 0) return 0;
    if (dy > max_ticks) dy = max_ticks;
    if (dy < -max_ticks) dy = -max_ticks;
    var ticks = @as(i32, @intFromFloat(dy));
    if (ticks == 0) ticks = if (dy > 0) 1 else -1;
    return ticks;
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
```

- [ ] **Step 1.2:** Register in `src/headless/tests.zig` after the `resize_rounding` import:
  ```zig
  _ = @import("tests/wheel_ticks.zig");
  ```
- [ ] **Step 1.3:** RED gate: the mirror tests pass immediately (they test the mirror), so the meaningful gate here is compile + suite baseline: `mise x zig@0.15.2 -- zig build test` → no new failures. (True RED for the C side is impossible headlessly; the mirror pins intent, per the `resize_rounding.zig` precedent. The behavioral RED is §1.1's per-event emission, removed in Task 2.)

### Task 2: Implementation

**Files:** Create `src/app/wheel_ticks.h`. Modify `src/app/macos_input_private.h:12` area (two ivars), `src/app/macos_input.m:1053-1112` (`scrollWheel:`) and its includes.

**Interfaces — produces:** `static inline int attyx_wheel_ticks(double* accum, double dy, int precise, double cell_h)`.

- [ ] **Step 2.1:** Create `src/app/wheel_ticks.h`:

```c
// Attyx — wheel delta -> scroll tick conversion (macOS platform layer)
//
// Converts NSEvent scroll deltas into whole scroll ticks:
//  - precise (trackpad, pixel deltas): accumulate into *accum; one tick per
//    cell_h points of travel; the fractional remainder persists across
//    events, which makes momentum streams proportional to glide distance.
//  - discrete (wheel, line deltas): trunc(dy) ticks, at least one in the
//    direction of dy; dy == 0 (pure horizontal tilt) emits nothing.
//
// Returns signed tick count (positive = scroll up).
// Semantics mirrored by src/headless/tests/wheel_ticks.zig — keep in sync.

#ifndef ATTYX_WHEEL_TICKS_H
#define ATTYX_WHEEL_TICKS_H

// Max ticks per event: 2 x ATTYX_MAX_ROWS. Real hardware deltas sit two
// orders of magnitude below; a synthetic event with a huge delta must not
// saturate the int cast (C UB) or drive an unbounded emission loop, and
// must not bank future ticks in the accumulator.
#define ATTYX_WHEEL_MAX_TICKS 512.0

static inline int attyx_wheel_ticks(double* accum, double dy, int precise,
                                    double cell_h) {
    if (precise) {
        *accum += dy;
        double threshold = cell_h > 0.0 ? cell_h : 16.0;
        double limit = ATTYX_WHEEL_MAX_TICKS * threshold;
        if (*accum > limit) *accum = limit;
        if (*accum < -limit) *accum = -limit;
        int ticks = (int)(*accum / threshold);
        *accum -= (double)ticks * threshold;
        return ticks;
    }
    if (dy == 0.0) return 0;
    if (dy > ATTYX_WHEEL_MAX_TICKS) dy = ATTYX_WHEEL_MAX_TICKS;
    if (dy < -ATTYX_WHEEL_MAX_TICKS) dy = -ATTYX_WHEEL_MAX_TICKS;
    int ticks = (int)dy;
    if (ticks == 0) ticks = (dy > 0.0) ? 1 : -1;
    return ticks;
}

#endif // ATTYX_WHEEL_TICKS_H
```

- [ ] **Step 2.2:** `src/app/macos_input_private.h` — replace `CGFloat _scrollAccum;` with:

```c
    CGFloat _scrollAccum;
    CGFloat _sgrScrollAccum;
    CGFloat _popupScrollAccum;
```

- [ ] **Step 2.3:** In `src/app/macos_input.m`, add `#include "wheel_ticks.h"` next to `#include "macos_internal.h"`, then replace the whole `scrollWheel:` method (`:1053-1112`) with:

```objc
- (void)scrollWheel:(NSEvent *)event {
    double dy = (double)event.scrollingDeltaY;
    int precise = event.hasPreciseScrollingDeltas ? 1 : 0;
    double cellH = (double)g_cell_pt_h;

    if (g_popup_active) {
        if (g_popup_mouse_tracking && g_popup_mouse_sgr) {
            double accum = (double)_popupScrollAccum;
            int ticks = attyx_wheel_ticks(&accum, dy, precise, cellH);
            _popupScrollAccum = (CGFloat)accum;
            if (ticks == 0) return;
            int col, row;
            mouseCell0(event, self, &col, &row);
            int pc, pr;
            if (popupHitTest(col, row, &pc, &pr)) {
                int btn = (ticks > 0 ? 64 : 65) | mouseModifiers(event.modifierFlags);
                int n = ticks > 0 ? ticks : -ticks;
                for (int i = 0; i < n; i++) sendSgrMousePopup(btn, pc, pr, YES);
            }
        }
        return;
    }
    if (g_mouse_tracking && g_mouse_sgr) {
        double accum = (double)_sgrScrollAccum;
        int ticks = attyx_wheel_ticks(&accum, dy, precise, cellH);
        _sgrScrollAccum = (CGFloat)accum;
        if (ticks == 0) return;
        int col, row;
        mouseCell(event, self, &col, &row);
        int btn = (ticks > 0 ? 64 : 65) | mouseModifiers(event.modifierFlags);
        int n = ticks > 0 ? ticks : -ticks;
        for (int i = 0; i < n; i++) sendSgrMouse(btn, col, row, YES);
        return;
    }

    double accum = (double)_scrollAccum;
    int lines = attyx_wheel_ticks(&accum, dy, precise, cellH);
    _scrollAccum = (CGFloat)accum;
    if (lines == 0) return;

    // Alt screen (TUI apps without mouse tracking): translate scroll into
    // up/down arrow key sequences so apps like less/man/vim can scroll.
    if (g_alt_screen) {
        char letter = (lines > 0) ? 'A' : 'B';
        int n = lines > 0 ? lines : -lines;
        uint8_t buf[3] = { 0x1b, g_cursor_keys_app ? 'O' : '[', (uint8_t)letter };
        for (int i = 0; i < n; i++) attyx_send_input(buf, 3);
        return;
    }

    // Overlay scroll: check before viewport scrollback
    int gcol, grow;
    mouseCell0(event, self, &gcol, &grow);
    if (g_overlay_has_actions) {
        if (attyx_overlay_scroll(gcol, grow, lines)) return;
        // Not on overlay — fall through to viewport scroll
    }
    // Route to the pane under the cursor (engine-space col, grid-space row).
    attyx_scroll_at(gcol - g_grid_left_offset, grow, lines);
}
```

- [ ] **Step 2.4:** `mise x zig@0.15.2 -- zig build` → clean; `mise x zig@0.15.2 -- zig build test` → no new failures (exe_tests compiles the ObjC; mirror tests green).

### Task 3: Verify + commit

- [ ] **Step 3.1:** Full suite → no new failures. Sizes: `wheel_ticks.h` ~35, `wheel_ticks.zig` ~130, `macos_input.m` net +<10.
- [ ] **Step 3.2:** Commit:

```bash
git add src/app/wheel_ticks.h src/app/macos_input.m src/app/macos_input_private.h \
        src/headless/tests.zig src/headless/tests/wheel_ticks.zig \
        docs/wheel-sgr-accumulation-fix-design.md docs/wheel-sgr-accumulation-fix-plan.md
git commit -m "fix: wheel scroll in mouse-tracking TUIs emitted one tick per event

The SGR mouse-wheel path sent exactly one wheel tick (button 64/65) per
NSEvent regardless of delta magnitude, and the intended 3x attenuation
(dy /= 3.0 before an exact ==0 check) was dead code. A trackpad flick
delivers dozens of pixel-delta events plus a momentum tail, so
mouse-tracking TUIs (htop, lazygit, vim with mouse=a) received 30-100+
ticks per gesture and scrolled by hundreds of lines; discrete wheels
conversely under-scrolled (accelerated multi-line deltas collapsed to one
tick).

Extract the already-correct pixel accumulator (used by the scrollback and
alt-screen paths) into a pure helper, wheel_ticks.h, and use it in all
three scrollWheel paths with independent accumulators: one tick per cell
height of travel for precise deltas, trunc(dy) ticks for discrete ones.
The helper also clamps to +-512 ticks per event so a synthetic huge delta
cannot saturate the int cast or drive an unbounded emission loop, guards
NaN, and fixes a phantom -1 tick for pure-horizontal tilt events (dy == 0
hit the min-one branch).

Design: docs/wheel-sgr-accumulation-fix-design.md"
```

---

## Self-review checklist

- Spec coverage: design §3.1 → Task 2.1; §3.2 accumulators → Tasks 2.2/2.3; §3.3 deltas rows 1-4 → Task 2.3, row 5 (dy==0) → helper guard + test; §6 tests 1-7 → Task 1.1 (momentum=test 2, reversal=test 4, fallback=test 5, clamp=test 8, parity=test 9, discrete=tests 6-7). ✓
- No placeholders: literal code/commands throughout. ✓
- Type consistency: `attyx_wheel_ticks(double*, double, int, double)` identical in Tasks 2.1/2.3; mirror uses f64/bool equivalently. ✓
- Post-implementation corrections (review cycle 2, applied to shipped files
  but not back-ported into every plan fence): NaN guard at the top of the
  helper and mirror; three additional tests (negative precise clamp,
  mixed-stream residue preservation, NaN) — final content: shipped files
  (12 tests, `wheel_ticks.h` 47 lines). Step 3.1's "~35" size estimate is
  superseded.
