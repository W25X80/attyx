# macOS Display-Scale Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix grid poisoning on Retina scale transitions (design: `docs/macos-display-scale-fix-design.md`) plus restore the dropped #215 epsilon fix.

**Architecture:** Scale-coherence guard in the drawable callback; atomic generation-tagged resize word; rebuild-reason split; unconditional coherent republish after every glyph-cache rebuild. All changes in the macOS platform layer + one shared header + headless tests.

**Tech stack:** Objective-C (AppKit/Metal), C11 `<stdatomic.h>`, Zig headless tests.

## Global constraints

- **Toolchain:** the project requires Zig 0.15.2 (`build.zig.zon:28`); the
  system `zig` is 0.16.0 and cannot compile `build.zig`. Run every build/test
  gate as `mise x zig@0.15.2 -- zig build test` (0.15.2 is installed via
  `mise install zig@0.15.2`).
- **Known pre-existing failure:** on the untouched tree, `zig build test`
  fails 1/440: `app.daemon.agent_status_test` "agent status re-shipped when a
  pane becomes newly active" (timeout in `test_harness.zig:234`). The gate
  for every task is therefore: *no new failures* — 439/440 with only that
  same daemon timeout is a PASS.
- New files must stay under ~600 lines (project rule). Several touched
  platform files already exceed it (`platform_macos.m` 1027, `macos_input.m`
  1114); they are grandfathered — this change grows them by +23 and +22
  lines respectively (the arm helper, the consumer rewrite, and the C4
  override are the plan's own literal code) and must not grow them further.
- `attyx_check_resize` C ABI must not change (`src/app/bridge.h:97`); zero Zig-side diffs.
- Linux/Windows platform files: only the mechanical epsilon restoration (Task 1), nothing else.
- Branch: `fix/macos-display-scale`. Two commits: (1) epsilon restoration, (2) scale fix.
- Verify after each task: `zig build test` (and full compile via exe_tests on macOS).

---

### Task 1: Restore #215 epsilon (`0.01f` → `0.001f`) — separate commit

**Files:** Modify `src/app/macos_renderer.m:229-230`, `src/app/platform_macos.m:541-542`, `src/app/platform_linux.c:423-424,621-622`, `src/app/linux_input.c:1302-1303`, `src/app/platform_windows.c:402-403,569-570`.

- [ ] **Step 1.1:** In each listed line replace `+ 0.01f` with `+ 0.001f` (14 lines total; these are exactly the sites commit `4ee6101` changed before the squash-merge dropped it).
- [ ] **Step 1.2:** Verify no `0.01f` remains in grid formulas: `grep -rn "0\.01f" src/app/*.m src/app/*.c` → expect no `new_cols`/`new_rows` lines.
- [ ] **Step 1.3:** Run `mise x zig@0.15.2 -- zig build test` → expect no new failures (439/440, only the known daemon timeout).
- [ ] **Step 1.4:** Commit on the new branch (explicit file list — the tree
  has unrelated untracked WIP files that `-A` would sweep in):
  ```bash
  git checkout -b fix/macos-display-scale
  git add src/app/macos_renderer.m src/app/platform_macos.m \
          src/app/platform_linux.c src/app/linux_input.c \
          src/app/platform_windows.c
  git commit -m "fix: restore #215 grid-rounding epsilon (0.01f -> 0.001f)

  PR #215 (43c3067) set out to tighten the pixel-to-cell epsilon to 0.001f
  on all platforms and added tests documenting that value, but the merged
  tree kept 0.01f in every platform file — the code change (present in
  branch commit 4ee6101) was lost on the PR branch before the squash-merge;
  only the tests landed. Re-apply it verbatim."
  ```

---

### Task 2: Shared header `src/app/resize_req.h`

**Files:** Create `src/app/resize_req.h`. Modify `src/app/macos_internal.h` (include it near the top, after existing includes).

**Produces (later tasks rely on):** `ATTYX_REBUILD_FONT`, `ATTYX_REBUILD_SCALE`, `attyx_resize_pack(uint32_t, int, int) -> uint64_t`, `attyx_resize_unpack(uint64_t, uint32_t*, int*, int*)`, `attyx_cells_fit(float px, float pad_a, float pad_b, float cell_px, int max) -> int`.

- [ ] **Step 2.1:** Create the header:

```c
// Attyx — resize-request word + drawable→grid formula (shared macOS logic)
//
// The resize request crosses from the AppKit main thread to the PTY thread.
// It is one 64-bit word [gen:32 | rows:16 | cols:16] so the consumer can
// never observe a torn rows/cols pair, and so requests computed against
// outdated glyph metrics are rejected by generation.
//
// Semantics are mirrored by src/headless/tests/resize_scale_coherence.zig —
// keep in sync.

#ifndef ATTYX_RESIZE_REQ_H
#define ATTYX_RESIZE_REQ_H

#include <stdint.h>

// g_needs_font_rebuild reason codes. Zig writers (ui/dispatch.zig,
// ui/actions.zig) write 1 on font/config changes; 2 is set only inside the
// macOS platform layer on display-scale changes.
#define ATTYX_REBUILD_FONT  1
#define ATTYX_REBUILD_SCALE 2

static inline uint64_t attyx_resize_pack(uint32_t gen, int rows, int cols) {
    return ((uint64_t)gen << 32)
         | ((uint64_t)(uint16_t)rows << 16)
         | (uint64_t)(uint16_t)cols;
}

static inline void attyx_resize_unpack(uint64_t word, uint32_t* gen,
                                       int* rows, int* cols) {
    *gen  = (uint32_t)(word >> 32);
    *rows = (int)((word >> 16) & 0xFFFFu);
    *cols = (int)(word & 0xFFFFu);
}

// Cells that fit in `px` pixels after subtracting padding. The 0.001f
// epsilon absorbs FP noise near exact-integer fits without promoting a
// fractional row to a phantom one (headless/tests/resize_rounding.zig).
static inline int attyx_cells_fit(float px, float pad_a, float pad_b,
                                  float cell_px, int max) {
    int n = (int)((px - pad_a - pad_b) / cell_px + 0.001f);
    if (n < 1) n = 1;
    if (n > max) n = max;
    return n;
}

#endif // ATTYX_RESIZE_REQ_H
```

- [ ] **Step 2.2:** In `src/app/macos_internal.h`, add `#include "resize_req.h"` next to the existing includes at the top, and `#include <stdatomic.h>`.

### Task 3: Atomic request state + consumer (`platform_macos.m`, `macos_internal.h`)

**Interfaces — produces:** `g_resize_req : _Atomic uint64_t`, `g_metrics_gen : _Atomic uint32_t` (declared `extern` in `macos_internal.h`, defined in `platform_macos.m`).

- [ ] **Step 3.1:** `src/app/macos_internal.h:57-58` — replace
  ```c
  extern volatile int g_pending_resize_rows;
  extern volatile int g_pending_resize_cols;
  ```
  with
  ```c
  extern _Atomic uint64_t g_resize_req;   // [gen:32 | rows:16 | cols:16], 0 = empty
  extern _Atomic uint32_t g_metrics_gen;  // bumped by rebuildFont after metrics install
  ```
- [ ] **Step 3.2:** `src/app/platform_macos.m:108-109` — replace the two `volatile int` definitions with
  ```c
  _Atomic uint64_t g_resize_req  = 0;
  _Atomic uint32_t g_metrics_gen = 0;
  ```
- [ ] **Step 3.3:** Rewrite `attyx_check_resize` (`platform_macos.m:211-221`), same signature:

```c
int attyx_check_resize(int* out_rows, int* out_cols) {
    uint64_t word = atomic_load_explicit(&g_resize_req, memory_order_acquire);
    if (word == 0) return 0;
    uint32_t gen;
    int pr, pc;
    attyx_resize_unpack(word, &gen, &pr, &pc);
    uint32_t cur_gen = atomic_load_explicit(&g_metrics_gen, memory_order_acquire);
    int stale = (gen != cur_gen) || pr <= 0 || pc <= 0;
    int noop  = (pr == g_rows && pc == g_cols);
    // Drain unless a newer word already replaced it (CAS keeps the newer one).
    atomic_compare_exchange_strong(&g_resize_req, &word, 0);
    if (stale || noop) return 0;
    *out_rows = pr;
    *out_cols = pc;
    return 1;
}
```

- [ ] **Step 3.4:** Rewrite the launch-time block (`platform_macos.m:538-551`) to publish through the word (same point-space arithmetic):

```objc
    {
        CGFloat viewW = termView.bounds.size.width;
        CGFloat viewH = termView.bounds.size.height;
        int new_cols = attyx_cells_fit((float)viewW, (float)g_padding_left,
                                       (float)g_padding_right, (float)g_cell_pt_w,
                                       ATTYX_MAX_COLS);
        int new_rows = attyx_cells_fit((float)viewH, (float)g_padding_top,
                                       (float)g_padding_bottom, (float)g_cell_pt_h,
                                       ATTYX_MAX_ROWS);
        if (new_cols != g_cols || new_rows != g_rows) {
            uint32_t gen = atomic_load_explicit(&g_metrics_gen, memory_order_relaxed);
            atomic_store_explicit(&g_resize_req,
                                  attyx_resize_pack(gen, new_rows, new_cols),
                                  memory_order_release);
        }
    }
```

- [ ] **Step 3.5:** `windowDidChangeScreen` (`platform_macos.m:626-630`) and `windowDidChangeBackingProperties` (`platform_macos.m:632-635`): replace `g_needs_font_rebuild = 1;` with
  ```c
  attyx_arm_scale_rebuild();
  ```
  and add this helper near the top of the file (after the includes), used by
  all SCALE arm-sites in this file:
  ```c
  // Arm a scale-reason rebuild unless a rebuild is already pending. CAS from
  // 0 so a concurrent FONT store (value 1, PTY thread on config reload)
  // always wins: FONT is the stronger reason — it also rasterizes at the
  // live scale and additionally applies the user's size change.
  static void attyx_arm_scale_rebuild(void) {
      int expected = 0;
      __atomic_compare_exchange_n(&g_needs_font_rebuild, &expected,
                                  ATTYX_REBUILD_SCALE, false,
                                  __ATOMIC_RELAXED, __ATOMIC_RELAXED);
  }
  ```
- [ ] **Step 3.6:** Compile: `mise x zig@0.15.2 -- zig build` → expect success.

### Task 4: `viewDidChangeBackingProperties` override (`macos_input.m`)

- [ ] **Step 4.1:** In `src/app/macos_input.m`, inside `@implementation AttyxView` (after `updateTrackingAreas`, `src/app/macos_input.m:334`), add:

```objc
// Keep the Metal layer's scale in lockstep with the window and rebuild the
// glyph cache when the scale actually changed. MTKView does the layer sync
// itself on healthy AppKit builds; doing it explicitly removes the
// dependency on undocumented ordering between backing-change and
// drawable-size callbacks. The rebuild is conditional: this notification
// also fires on first window attachment, where scales already match —
// arming there would rasterize the glyph atlas twice on every launch.
- (void)viewDidChangeBackingProperties {
    CGFloat before = self.layer.contentsScale;
    [super viewDidChangeBackingProperties];
    NSWindow* w = self.window;
    if (!w) return;
    self.layer.contentsScale = w.backingScaleFactor;
    if (fabs((double)before - (double)w.backingScaleFactor) > 0.001) {
        int expected = 0;
        __atomic_compare_exchange_n(&g_needs_font_rebuild, &expected,
                                    ATTYX_REBUILD_SCALE, false,
                                    __ATOMIC_RELAXED, __ATOMIC_RELAXED);
    }
}
```

- [ ] **Step 4.2:** Add `#include <math.h>` to `macos_input.m` if not already present (fabs), then compile: `mise x zig@0.15.2 -- zig build` → expect success.

### Task 5: Guard + reason split + coherent republish (`macos_renderer.m`)

**Consumes:** Task 2 helpers, Task 3 globals.

- [ ] **Step 5.1:** In `drawInMTKView`, replace the flag-consume block at `macos_renderer.m:185-188` (keep the method signature at line 184 intact) with an atomic exchange — this also closes the pre-existing lost-write window between the old load and clear:

```objc
    int rebuild_reason = __atomic_exchange_n(&g_needs_font_rebuild, 0, __ATOMIC_RELAXED);
    if (rebuild_reason) {
        [self rebuildFont:view reason:rebuild_reason];
    }
```

- [ ] **Step 5.2:** Add the publish helper to `AttyxRenderer` (before `rebuildFont`):

```objc
- (void)publishResize:(int)rows cols:(int)cols {
    uint32_t gen = atomic_load_explicit(&g_metrics_gen, memory_order_relaxed);
    atomic_store_explicit(&g_resize_req, attyx_resize_pack(gen, rows, cols),
                          memory_order_release);
}
```

- [ ] **Step 5.3:** Replace `mtkView:drawableSizeWillChange:` (`macos_renderer.m:224-238`), and add `#include <math.h>` to the file's includes (fabs is currently only transitively available):

```objc
// Live backing scale of the view's window. Single scale source for the
// guard and the rebuild path — window.backingScaleFactor is defined even
// while window.screen is transiently nil during screen transitions.
static CGFloat liveScale(MTKView* view) {
    NSWindow* w = view.window;
    if (w) return w.backingScaleFactor;
    return [NSScreen mainScreen].backingScaleFactor;
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
    // Scale-coherence guard: never pair a drawable sized for one screen with
    // glyph metrics rasterized for another. The rebuild path republishes the
    // grid once metrics match (rebuildFont:reason:).
    if (fabs((double)liveScale(view) - (double)_glyphCache.scale) > 0.001) {
        int expected = 0;
        __atomic_compare_exchange_n(&g_needs_font_rebuild, &expected,
                                    ATTYX_REBUILD_SCALE, false,
                                    __ATOMIC_RELAXED, __ATOMIC_RELAXED);
        _fullRedrawNeeded = YES;
        return;
    }
    float sc = _glyphCache.scale;
    int new_cols = attyx_cells_fit((float)size.width,  g_padding_left * sc,
                                   g_padding_right * sc, _glyphCache.glyph_w,
                                   ATTYX_MAX_COLS);
    int new_rows = attyx_cells_fit((float)size.height, g_padding_top * sc,
                                   g_padding_bottom * sc, _glyphCache.glyph_h,
                                   ATTYX_MAX_ROWS);
    [self publishResize:new_rows cols:new_cols];
    _fullRedrawNeeded = YES;
}
```

- [ ] **Step 5.4:** Replace `rebuildFont:` (`macos_renderer.m:197-222`) with `rebuildFont:reason:`, and update the declaration at `src/app/macos_renderer_private.h:51` from `- (void)rebuildFont:(MTKView*)view;` to `- (void)rebuildFont:(MTKView*)view reason:(int)reason;` (the declaration is definitively there):

```objc
- (void)rebuildFont:(MTKView*)view reason:(int)reason {
    // Release old Core Text fonts. Metal textures are ARC-managed.
    if (_glyphCache.font) CFRelease(_glyphCache.font);
    if (_glyphCache.font_bold) CFRelease(_glyphCache.font_bold);
    if (_glyphCache.font_italic) CFRelease(_glyphCache.font_italic);
    if (_glyphCache.font_bold_italic) CFRelease(_glyphCache.font_bold_italic);

    CGFloat scale = liveScale(view);
    _glyphCache = createGlyphCache(_device, scale);
    ligatureCacheClear();

    g_cell_pt_w = _glyphCache.glyph_w / _glyphCache.scale;
    g_cell_pt_h = _glyphCache.glyph_h / _glyphCache.scale;
    g_cell_w_pts = (float)g_cell_pt_w;
    g_cell_h_pts = (float)g_cell_pt_h;

    // New metrics are installed: requests packed with older generations are
    // now stale and rejected by attyx_check_resize. The bump precedes
    // setContentSize: so the re-entrant size callback (if any) publishes
    // with the post-bump generation.
    atomic_fetch_add_explicit(&g_metrics_gen, 1, memory_order_release);

    NSWindow* window = view.window;
    if (reason == ATTYX_REBUILD_FONT && window) {
        // Font/config change: preserve the grid, resize the window to fit it
        // at the new cell size — content size clamped to what fits the
        // screen (origin is left alone).
        NSSize target = NSMakeSize(g_cols * g_cell_pt_w + g_padding_left + g_padding_right,
                                   g_rows * g_cell_pt_h + g_padding_top  + g_padding_bottom);
        if (window.screen) {
            NSSize maxContent = [window contentRectForFrameRect:window.screen.visibleFrame].size;
            if (target.width  > maxContent.width)  target.width  = maxContent.width;
            if (target.height > maxContent.height) target.height = maxContent.height;
        }
        [window setContentSize:target];
    }
    // Scale change: the window's point frame is preserved deliberately —
    // dragging across displays must never reflow the shell.

    // Unconditional coherent republish: bounds × live scale paired with the
    // metrics just rasterized at that same scale. Never reads drawableSize —
    // whether or not the drawable has caught up with a screen change, this
    // publishes the settled-state grid; the guarded callback later
    // republishes the identical value (no-op suppressed). Also covers the
    // two no-callback cases: pure scale change (point size unchanged) and
    // clamped font change (target == current size).
    {
        float sc = _glyphCache.scale;
        CGSize bounds = view.bounds.size;
        int new_cols = attyx_cells_fit((float)(bounds.width * sc),
                                       g_padding_left * sc, g_padding_right * sc,
                                       _glyphCache.glyph_w, ATTYX_MAX_COLS);
        int new_rows = attyx_cells_fit((float)(bounds.height * sc),
                                       g_padding_top * sc, g_padding_bottom * sc,
                                       _glyphCache.glyph_h, ATTYX_MAX_ROWS);
        [self publishResize:new_rows cols:new_cols];
    }

    _fullRedrawNeeded = YES;
}
```

- [ ] **Step 5.5:** Grep for stragglers: `grep -rn "g_pending_resize" src/app/*.m src/app/macos_internal.h` → expect none (Linux/Windows keep theirs in their own files).
- [ ] **Step 5.6:** Compile + tests: `mise x zig@0.15.2 -- zig build test` → expect no new failures.

### Task 6: Headless tests

**Files:** Create `src/headless/tests/resize_scale_coherence.zig`; modify `src/headless/tests.zig` (add `_ = @import("tests/resize_scale_coherence.zig");` after the `resize_rounding` import at `src/headless/tests.zig:18`).

- [ ] **Step 6.1:** Write the test file. *(Post-implementation correction:
  the block below is the pre-implementation draft — it contains
  `correct / 2`, which does not compile under Zig 0.15.2 (signed division
  needs `@divTrunc`), and a wrong clamp constant 500 (real `ATTYX_MAX_COLS`
  is 512, `ATTYX_MAX_ROWS` 256, `bridge.h:6-7`). The shipped, canonical
  content is `src/headless/tests/resize_scale_coherence.zig`, which also
  adds review-cycle-2 tests: CAS-drain semantics, gen wraparound, the
  2x→1x halving direction, ATTYX_MAX clamping, and empty-word rejection.)*

```zig
//! Tests for the atomic resize-request word and the scale-coherence rules
//! introduced by the macOS display-scale fix
//! (docs/macos-display-scale-fix-design.md).
//!
//! Mirrors the static-inline helpers in src/app/resize_req.h — keep in sync.

const std = @import("std");

// --- mirrors of src/app/resize_req.h ---------------------------------------

fn pack(gen: u32, rows: u16, cols: u16) u64 {
    return (@as(u64, gen) << 32) | (@as(u64, rows) << 16) | @as(u64, cols);
}

fn unpack(word: u64) struct { gen: u32, rows: i32, cols: i32 } {
    return .{
        .gen = @intCast(word >> 32),
        .rows = @intCast((word >> 16) & 0xFFFF),
        .cols = @intCast(word & 0xFFFF),
    };
}

fn cellsFit(px: f32, pad_a: f32, pad_b: f32, cell_px: f32, max: i32) i32 {
    const eps: f32 = 0.001;
    var n = @as(i32, @intFromFloat((px - pad_a - pad_b) / cell_px + eps));
    if (n < 1) n = 1;
    if (n > max) n = max;
    return n;
}

/// Mirror of the consumer's accept/reject rule in attyx_check_resize.
fn accepted(word: u64, current_gen: u32, cur_rows: i32, cur_cols: i32) bool {
    if (word == 0) return false;
    const r = unpack(word);
    if (r.gen != current_gen) return false;
    if (r.rows <= 0 or r.cols <= 0) return false;
    if (r.rows == cur_rows and r.cols == cur_cols) return false;
    return true;
}

/// Mirror of the scale-coherence guard in mtkView:drawableSizeWillChange:.
fn guardAllowsPublish(view_scale: f32, cache_scale: f32) bool {
    return @abs(view_scale - cache_scale) <= 0.001;
}

// --- pack/unpack ------------------------------------------------------------

test "pack/unpack round-trips across field extremes" {
    const cases = [_]struct { gen: u32, rows: u16, cols: u16 }{
        .{ .gen = 0, .rows = 1, .cols = 1 },
        .{ .gen = 1, .rows = 24, .cols = 80 },
        .{ .gen = 0xFFFF_FFFF, .rows = 0xFFFF, .cols = 0xFFFF },
        .{ .gen = 7, .rows = 500, .cols = 500 },
    };
    for (cases) |c| {
        const r = unpack(pack(c.gen, c.rows, c.cols));
        try std.testing.expectEqual(@as(u32, c.gen), r.gen);
        try std.testing.expectEqual(@as(i32, c.rows), r.rows);
        try std.testing.expectEqual(@as(i32, c.cols), r.cols);
    }
}

test "single-word request cannot tear: fields travel together" {
    // Two successive publishes; any single load sees exactly one of them,
    // never a mixture. Structural with one u64 — assert distinctness of the
    // whole words to document the invariant.
    const a = pack(3, 40, 120);
    const b = pack(3, 62, 200);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(i32, 40), unpack(a).rows);
    try std.testing.expectEqual(@as(i32, 200), unpack(b).cols);
}

// --- consumer accept/reject -------------------------------------------------

test "stale generation is rejected" {
    const word = pack(4, 48, 160); // packed before a rebuild bumped gen to 5
    try std.testing.expect(!accepted(word, 5, 24, 80));
}

test "matching generation with a real change is accepted" {
    const word = pack(5, 48, 160);
    try std.testing.expect(accepted(word, 5, 24, 80));
}

test "no-op resize is suppressed" {
    const word = pack(5, 24, 80);
    try std.testing.expect(!accepted(word, 5, 24, 80));
}

// --- scale coherence --------------------------------------------------------

test "guard blocks publish while cache scale lags the screen" {
    // Window just moved 1x -> 2x; drawable already 2x, cache still 1x.
    try std.testing.expect(!guardAllowsPublish(2.0, 1.0));
    // And the reverse transition, 2x -> 1x.
    try std.testing.expect(!guardAllowsPublish(1.0, 2.0));
    // Same scale: publish allowed.
    try std.testing.expect(guardAllowsPublish(2.0, 2.0));
    try std.testing.expect(guardAllowsPublish(1.0, 1.0));
}

test "poisoned grid of the Retina bug would have been blocked" {
    // Reproduction of the original defect, numbers from a 14pt font:
    // cell 8pt -> glyph_px 8 at 1x, 17 at 2x (pixel snapping).
    // Window 800x600pt moves from a 1x screen to a 2x screen.
    const bounds_w: f32 = 800.0;
    const drawable_w_2x: f32 = bounds_w * 2.0;
    const glyph_px_1x: f32 = 8.0; // stale cache
    const glyph_px_2x: f32 = 17.0; // correct cache

    // Old code paired the 2x drawable with the 1x metrics: ~2x the columns.
    const poisoned = cellsFit(drawable_w_2x, 0, 0, glyph_px_1x, 500);
    const correct = cellsFit(drawable_w_2x, 0, 0, glyph_px_2x, 500);
    try std.testing.expect(poisoned > correct + correct / 2);

    // New code: the guard refuses the incoherent pairing entirely...
    try std.testing.expect(!guardAllowsPublish(2.0, 1.0));
    // ...and after the rebuild installs 2x metrics, the published grid fits:
    // cols * glyph_px <= drawable width (no overflow).
    try std.testing.expect(@as(f32, @floatFromInt(correct)) * glyph_px_2x <= drawable_w_2x);
}

test "republished grid after rebuild always fits the drawable" {
    // Sweep bounds/scales/cells: the grid published with matched metrics
    // never overflows the drawable (invariant I1 of the design doc).
    const scales = [_]f32{ 1.0, 2.0 };
    const cells_pt = [_]f32{ 6.0, 8.0, 8.5, 10.0, 12.0, 17.0 };
    const widths_pt = [_]f32{ 300.0, 640.0, 800.0, 1440.0, 2560.0 };
    const pads_pt = [_]f32{ 0.0, 4.0, 8.0 };
    for (scales) |s| {
        for (cells_pt) |cpt| {
            for (widths_pt) |w| {
                for (pads_pt) |p| {
                    const cell_px = @round(cpt * s);
                    const drawable = w * s;
                    const pad_px = p * s;
                    const cols = cellsFit(drawable, pad_px, pad_px, cell_px, 500);
                    const used = @as(f32, @floatFromInt(cols)) * cell_px + 2.0 * pad_px;
                    // 1px slack for integer-fb rounding, as in resize_rounding.zig.
                    try std.testing.expect(used <= drawable + 1.0 or cols == 1);
                }
            }
        }
    }
}
```

- [ ] **Step 6.2:** Register in `src/headless/tests.zig` (line 18 area):
  ```zig
  _ = @import("tests/resize_scale_coherence.zig");
  ```
- [ ] **Step 6.3:** Run `mise x zig@0.15.2 -- zig build test` → expect no new failures (mirror tests pass immediately; they document the C header semantics by convention, like `resize_rounding.zig`).

### Task 7: Final verification + commit 2

- [ ] **Step 7.1:** `mise x zig@0.15.2 -- zig build test` full suite → no new failures. `mise x zig@0.15.2 -- zig build` → clean.
- [ ] **Step 7.2:** File-size check: new files (`resize_req.h`, `resize_scale_coherence.zig`) under 600 lines; pre-existing oversized platform files grew by <15 lines each.
- [ ] **Step 7.3:** Commit:

```bash
git add src/app/resize_req.h src/app/macos_internal.h src/app/platform_macos.m \
        src/app/macos_renderer.m src/app/macos_renderer_private.h src/app/macos_input.m \
        src/app/ui/event_loop.zig \
        src/headless/tests.zig src/headless/tests/resize_scale_coherence.zig \
        src/headless/tests/resize_rounding.zig \
        docs/macos-display-scale-fix-design.md docs/macos-display-scale-fix-plan.md
git commit -m "fix: grid poisoning on Retina display-scale transitions (macOS)

Moving the window between displays with different backing scales computed
the terminal grid from the new drawable size divided by stale glyph
metrics, yielding ~2x the rows/cols that fit; the state was persistent
because a pure scale change leaves the content size in points unchanged,
so no size callback ever recomputed it.

- Scale-coherence guard: drawableSizeWillChange refuses to pair a drawable
  with glyph metrics rasterized for a different scale.
- Atomic resize request [gen|rows|cols] in one 64-bit word: no torn
  rows/cols pairs across threads, stale-metrics requests rejected by
  generation. attyx_check_resize keeps its ABI; Zig side unchanged.
- Rebuild-reason split: font changes keep the grid and resize the window
  (now clamped to the screen); scale changes keep the window's point frame
  and republish the grid — dragging across displays never resizes the
  window (the grid may shift by the per-scale cell snapping delta).
- Explicit layer.contentsScale sync in viewDidChangeBackingProperties.
- Headless tests for the request word, accept/reject rules, and the
  scale-coherence invariant.

Design: docs/macos-display-scale-fix-design.md"
```

---

## Self-review checklist (run after writing, before implementation)

- Spec coverage: C1→Task 5.3, C2→Tasks 2-3, C3→Tasks 3.5/5.1/5.4, C4→Task 4, C5→Tasks 2/6, §1.1b→Task 1. ✓
- No placeholders: every step has literal code or a literal command. ✓
- Type consistency: `attyx_cells_fit` signature identical across Tasks 2/3/5; `publishResize:cols:` defined in 5.2 before uses in 5.3/5.4. ✓
- Resolved during review: `rebuildFont:` is declared at `src/app/macos_renderer_private.h:51`; Step 5.4 updates it unconditionally.
- Review cycle 1 applied (3 same-model adversarial agents): toolchain gate corrected (Zig 0.15.2 via mise), republish source changed from `drawableSize` to `bounds × liveScale` (ordering hole), unconditional republish after every rebuild (liveness hole), conditional arming in `viewDidChangeBackingProperties` (double-rasterization on launch), atomic flag arming/consume (value-carrying race), clamp via `contentRectForFrameRect:`, explicit `git add` lists, known pre-existing daemon-test failure documented.
