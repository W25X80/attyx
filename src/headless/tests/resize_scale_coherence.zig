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

/// Mirror of the consumer's accept/reject rule in attyx_check_resize
/// (src/app/platform_macos.m).
fn accepted(word: u64, current_gen: u32, cur_rows: i32, cur_cols: i32) bool {
    if (word == 0) return false;
    const r = unpack(word);
    if (r.gen != current_gen) return false;
    if (r.rows <= 0 or r.cols <= 0) return false;
    if (r.rows == cur_rows and r.cols == cur_cols) return false;
    return true;
}

/// Mirror of the scale-coherence guard in mtkView:drawableSizeWillChange:
/// (src/app/macos_renderer.m).
fn guardAllowsPublish(view_scale: f32, cache_scale: f32) bool {
    return @abs(view_scale - cache_scale) <= 0.001;
}

// --- pack/unpack ------------------------------------------------------------

test "pack/unpack round-trips across field extremes" {
    const cases = [_]struct { gen: u32, rows: u16, cols: u16 }{
        .{ .gen = 0, .rows = 1, .cols = 1 },
        .{ .gen = 1, .rows = 24, .cols = 80 },
        .{ .gen = 0xFFFF_FFFF, .rows = 0xFFFF, .cols = 0xFFFF },
        .{ .gen = 7, .rows = 256, .cols = 512 }, // ATTYX_MAX_ROWS/COLS
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
    // never a mixture. Structural with one u64 — assert both fields decode
    // from the same word to document the invariant.
    const a = pack(3, 40, 120);
    const b = pack(3, 62, 200);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(i32, 40), unpack(a).rows);
    try std.testing.expectEqual(@as(i32, 120), unpack(a).cols);
    try std.testing.expectEqual(@as(i32, 62), unpack(b).rows);
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

test "empty word is rejected" {
    try std.testing.expect(!accepted(0, 0, 24, 80));
}

/// Mirror of the drain in attyx_check_resize: CAS(loaded -> 0). A newer
/// word that replaced the loaded one survives; the loaded word — accepted,
/// stale, or noop — never lingers.
fn drain(slot: *u64, loaded: u64) void {
    if (slot.* == loaded) slot.* = 0;
}

test "drain removes only the exact loaded word; a newer request survives" {
    var slot: u64 = pack(5, 48, 160);
    const loaded = slot;
    slot = pack(5, 50, 170); // publisher wins the race after the load
    drain(&slot, loaded);
    try std.testing.expectEqual(pack(5, 50, 170), slot);
}

test "stale and noop words are drained, not retained" {
    var stale_word: u64 = pack(4, 48, 160); // gen 4 < current 5
    try std.testing.expect(!accepted(stale_word, 5, 24, 80));
    drain(&stale_word, stale_word);
    try std.testing.expectEqual(@as(u64, 0), stale_word);
}

test "generation check is pure equality: wraparound-safe" {
    try std.testing.expect(accepted(pack(0xFFFF_FFFF, 48, 160), 0xFFFF_FFFF, 24, 80));
    // Bump wraps 0xFFFFFFFF -> 0: the pre-wrap word is stale, the post-wrap fresh.
    try std.testing.expect(!accepted(pack(0xFFFF_FFFF, 48, 160), 0, 24, 80));
    try std.testing.expect(accepted(pack(0, 48, 160), 0, 24, 80));
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
    // natural advance ~8.43pt -> glyph_px 8 at 1x, 17 at 2x (pixel
    // snapping). Window 800pt wide moves from a 1x screen to a 2x screen.
    const bounds_w: f32 = 800.0;
    const drawable_w_2x: f32 = bounds_w * 2.0;
    const glyph_px_1x: f32 = 8.0; // stale cache
    const glyph_px_2x: f32 = 17.0; // correct cache

    // Old code paired the 2x drawable with the 1x metrics: ~2x the columns.
    const poisoned = cellsFit(drawable_w_2x, 0, 0, glyph_px_1x, 512);
    const correct = cellsFit(drawable_w_2x, 0, 0, glyph_px_2x, 512);
    try std.testing.expect(poisoned > correct + @divTrunc(correct, 2));

    // New code: the guard refuses the incoherent pairing entirely...
    try std.testing.expect(!guardAllowsPublish(2.0, 1.0));
    // ...and after the rebuild installs 2x metrics, the published grid fits:
    // cols * glyph_px <= drawable width (no overflow).
    try std.testing.expect(@as(f32, @floatFromInt(correct)) * glyph_px_2x <= drawable_w_2x);
}

test "reverse transition (2x -> 1x) would have halved the grid" {
    const drawable_w_1x: f32 = 800.0; // drawable already back at 1x
    const poisoned = cellsFit(drawable_w_1x, 0, 0, 17.0, 512); // stale 2x metrics: 47
    const correct = cellsFit(drawable_w_1x, 0, 0, 8.0, 512); // rebuilt 1x metrics: 100
    try std.testing.expect(poisoned < correct - @divTrunc(correct, 3));
    try std.testing.expect(!guardAllowsPublish(1.0, 2.0));
}

test "cellsFit clamps to ATTYX_MAX" {
    // 5K-wide 2x drawable with a tiny cell: 5120/6 = 853 -> ATTYX_MAX_COLS.
    try std.testing.expectEqual(@as(i32, 512), cellsFit(5120.0, 0, 0, 6.0, 512));
    // 4320/12 = 360 -> ATTYX_MAX_ROWS.
    try std.testing.expectEqual(@as(i32, 256), cellsFit(4320.0, 0, 0, 12.0, 256));
}

test "republished grid after rebuild always fits the settled drawable" {
    // The rebuild republish computes from bounds x live-scale paired with
    // metrics rasterized at that same scale (invariant I1 of the design
    // doc). Sweep bounds/scales/cells/pads: never overflows.
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
                    const cols = cellsFit(drawable, pad_px, pad_px, cell_px, 512);
                    const used = @as(f32, @floatFromInt(cols)) * cell_px + 2.0 * pad_px;
                    // 1px slack for integer-fb rounding, as in resize_rounding.zig.
                    try std.testing.expect(used <= drawable + 1.0 or cols == 1);
                }
            }
        }
    }
}
