const std = @import("std");

const policy = @cImport({
    @cInclude("glyph_cache_policy.h");
});

test "glyph map retains more than the legacy 4096 entries" {
    var map: policy.GlyphMap = undefined;
    const max_capacity = policy.glyphMapCapacityForEntries(8192);
    try std.testing.expect(policy.glyphMapInit(
        &map,
        policy.GLYPH_MAP_INITIAL_CAPACITY,
        max_capacity,
    ));
    defer policy.glyphMapDeinit(&map);

    const entry_count: u32 = 5000;
    for (0..entry_count) |index| {
        const key: u32 = @intCast(index + 1);
        const slot: c_int = @intCast(index);
        try std.testing.expect(policy.glyphMapPrepareInsert(&map, key));
        try std.testing.expect(policy.glyphMapInsertPrepared(&map, key, slot));
    }

    try std.testing.expect(map.capacity > policy.GLYPH_MAP_INITIAL_CAPACITY);
    try std.testing.expectEqual(entry_count, map.count);
    for (0..entry_count) |index| {
        const key: u32 = @intCast(index + 1);
        const expected: c_int = @intCast(index);
        try std.testing.expectEqual(expected, policy.glyphMapLookup(&map, key));
    }
}

test "glyph map fails explicitly at its bounded maximum" {
    var map: policy.GlyphMap = undefined;
    try std.testing.expect(policy.glyphMapInit(&map, 8, 8));
    defer policy.glyphMapDeinit(&map);

    for (0..5) |index| {
        const key: u32 = @intCast(index + 1);
        try std.testing.expect(policy.glyphMapPrepareInsert(&map, key));
        try std.testing.expect(policy.glyphMapInsertPrepared(
            &map,
            key,
            @intCast(index),
        ));
    }

    try std.testing.expect(!policy.glyphMapPrepareInsert(&map, 99));
    try std.testing.expectEqual(@as(u32, 5), map.count);
    try std.testing.expectEqual(@as(c_int, -1), policy.glyphMapLookup(&map, 99));
}

test "glyph cache failure latch blocks work until reset" {
    var latch: policy.GlyphCacheFailureLatch = undefined;
    policy.glyphCacheFailureLatchReset(&latch);
    try std.testing.expect(policy.glyphCacheFailureLatchAllowsWork(&latch));

    policy.glyphCacheFailureLatchTrip(&latch);
    try std.testing.expect(!policy.glyphCacheFailureLatchAllowsWork(&latch));

    policy.glyphCacheFailureLatchTrip(&latch);
    try std.testing.expect(!policy.glyphCacheFailureLatchAllowsWork(&latch));

    policy.glyphCacheFailureLatchReset(&latch);
    try std.testing.expect(policy.glyphCacheFailureLatchAllowsWork(&latch));
}

test "color failure keeps monochrome rasterization enabled" {
    var latch: policy.GlyphCacheFailureLatch = undefined;
    policy.glyphCacheFailureLatchReset(&latch);

    policy.glyphCacheFailureLatchMarkColorUnavailable(&latch);

    try std.testing.expect(policy.glyphCacheFailureLatchAllowsWork(&latch));
}

test "color failure blocks color attempts until cache reset" {
    var latch: policy.GlyphCacheFailureLatch = undefined;
    policy.glyphCacheFailureLatchReset(&latch);
    try std.testing.expect(policy.glyphCacheFailureLatchAllowsColorWork(&latch));

    policy.glyphCacheFailureLatchMarkColorUnavailable(&latch);
    try std.testing.expect(!policy.glyphCacheFailureLatchAllowsColorWork(&latch));

    policy.glyphCacheFailureLatchReset(&latch);
    try std.testing.expect(policy.glyphCacheFailureLatchAllowsColorWork(&latch));

    policy.glyphCacheFailureLatchTrip(&latch);
    try std.testing.expect(!policy.glyphCacheFailureLatchAllowsColorWork(&latch));
}

test "ASCII warmup rasterizes fallback first and covers printable ASCII once" {
    var seen = [_]bool{false} ** 95;
    for (0..seen.len) |index| {
        var codepoint: u32 = 0;
        try std.testing.expect(policy.glyphCacheAsciiWarmupCodepoint(
            @intCast(index),
            &codepoint,
        ));
        if (index == 0) try std.testing.expectEqual(@as(u32, '?'), codepoint);
        try std.testing.expect(codepoint >= 32 and codepoint <= 126);

        const seen_index: usize = @intCast(codepoint - 32);
        try std.testing.expect(!seen[seen_index]);
        seen[seen_index] = true;
    }

    for (seen) |was_seen| try std.testing.expect(was_seen);

    var codepoint: u32 = 0;
    try std.testing.expect(!policy.glyphCacheAsciiWarmupCodepoint(-1, &codepoint));
    try std.testing.expect(!policy.glyphCacheAsciiWarmupCodepoint(95, &codepoint));
}

test "atlas growth doubles without exceeding Metal height" {
    var growth: policy.GlyphAtlasGrowth = undefined;
    try std.testing.expect(policy.glyphAtlasPlanGrowth(
        32,
        32,
        32,
        1024,
        1,
        policy.GLYPH_ATLAS_MAX_TEXTURE_DIMENSION,
        &growth,
    ));
    try std.testing.expectEqual(@as(c_int, 64), growth.rows);
    try std.testing.expectEqual(@as(c_int, 2048), growth.height);
    try std.testing.expectEqual(@as(c_int, 2048), growth.max_slots);

    try std.testing.expect(policy.glyphAtlasPlanGrowth(
        32,
        32,
        256,
        8192,
        1,
        policy.GLYPH_ATLAS_MAX_TEXTURE_DIMENSION,
        &growth,
    ));
    try std.testing.expectEqual(@as(c_int, 512), growth.rows);
    try std.testing.expectEqual(
        @as(c_int, policy.GLYPH_ATLAS_MAX_TEXTURE_DIMENSION),
        growth.height,
    );
}

test "atlas growth rejects requests beyond final capacity" {
    var growth = policy.GlyphAtlasGrowth{
        .rows = 7,
        .height = 11,
        .max_slots = 13,
    };
    try std.testing.expect(!policy.glyphAtlasPlanGrowth(
        32,
        32,
        512,
        16384,
        1,
        policy.GLYPH_ATLAS_MAX_TEXTURE_DIMENSION,
        &growth,
    ));
    try std.testing.expectEqual(@as(c_int, 7), growth.rows);
    try std.testing.expectEqual(@as(c_int, 11), growth.height);
    try std.testing.expectEqual(@as(c_int, 13), growth.max_slots);
}

test "wide glyph reservation includes row padding" {
    try std.testing.expectEqual(
        @as(c_int, 1),
        policy.glyphAtlasWidePadding(31, 32),
    );
    try std.testing.expectEqual(
        @as(c_int, 0),
        policy.glyphAtlasWidePadding(30, 32),
    );
}

test "initial atlas geometry remains within texture limits" {
    var geometry: policy.GlyphAtlasGeometry = undefined;
    try std.testing.expect(policy.glyphAtlasInitialGeometry(
        600,
        600,
        policy.GLYPH_ATLAS_MAX_TEXTURE_DIMENSION,
        &geometry,
    ));
    try std.testing.expectEqual(@as(c_int, 27), geometry.cols);
    try std.testing.expectEqual(@as(c_int, 2), geometry.rows);
    try std.testing.expectEqual(@as(c_int, 16200), geometry.width);
    try std.testing.expectEqual(@as(c_int, 1200), geometry.height);
    try std.testing.expectEqual(@as(c_int, 2), geometry.max_rows);
    try std.testing.expectEqual(@as(c_int, 54), geometry.max_slots);

    try std.testing.expect(!policy.glyphAtlasInitialGeometry(
        policy.GLYPH_ATLAS_MAX_TEXTURE_DIMENSION + 1,
        16,
        policy.GLYPH_ATLAS_MAX_TEXTURE_DIMENSION,
        &geometry,
    ));

    try std.testing.expect(!policy.glyphAtlasInitialGeometry(
        policy.GLYPH_ATLAS_MAX_TEXTURE_DIMENSION / 2 + 1,
        16,
        policy.GLYPH_ATLAS_MAX_TEXTURE_DIMENSION,
        &geometry,
    ));
}

test "initial atlas geometry reserves one aggregate byte budget for gray and color" {
    var geometry: policy.GlyphAtlasGeometry = undefined;
    try std.testing.expect(policy.glyphAtlasInitialGeometry(
        512,
        32,
        policy.GLYPH_ATLAS_MAX_TEXTURE_DIMENSION,
        &geometry,
    ));

    try std.testing.expectEqual(@as(c_int, 32), geometry.rows);
    try std.testing.expectEqual(@as(c_int, 51), geometry.max_rows);
    try std.testing.expectEqual(@as(c_int, 1632), geometry.max_slots);

    const budget: usize = 128 * 1024 * 1024;
    var max_bytes: usize = 0;
    try std.testing.expect(policy.glyphAtlasPixelBytes(
        geometry.width,
        geometry.max_rows * 32,
        5,
        &max_bytes,
    ));
    try std.testing.expect(max_bytes <= budget);

    var one_more_row_bytes: usize = 0;
    try std.testing.expect(policy.glyphAtlasPixelBytes(
        geometry.width,
        (geometry.max_rows + 1) * 32,
        5,
        &one_more_row_bytes,
    ));
    try std.testing.expect(one_more_row_bytes > budget);
}

test "pixel byte calculation rejects overflow" {
    var bytes: usize = 0;
    try std.testing.expect(policy.glyphAtlasPixelBytes(512, 1024, 4, &bytes));
    try std.testing.expectEqual(@as(usize, 512 * 1024 * 4), bytes);

    try std.testing.expect(!policy.glyphAtlasPixelBytes(
        std.math.maxInt(c_int),
        std.math.maxInt(c_int),
        8,
        &bytes,
    ));
}

test "glyph texel coordinates remain stable across atlas growth" {
    const rect = policy.glyphAtlasTexelRect(4097, 32, 18, 32, 1);
    try std.testing.expectEqual(@as(c_int, 18), rect.x0);
    try std.testing.expectEqual(@as(c_int, 4096), rect.y0);
    try std.testing.expectEqual(@as(c_int, 36), rect.x1);
    try std.testing.expectEqual(@as(c_int, 4128), rect.y1);
}

test "encoded glyph slots decode before texel lookup" {
    var slot = policy.GlyphAtlasSlot{
        .index = 7,
        .width = 9,
        .color = false,
    };
    try std.testing.expect(policy.glyphAtlasDecodeSlot(
        123 | policy.GLYPH_WIDE_BIT | policy.GLYPH_COLOR_BIT,
        &slot,
    ));
    try std.testing.expectEqual(@as(c_int, 123), slot.index);
    try std.testing.expectEqual(@as(c_int, 2), slot.width);
    try std.testing.expect(slot.color);

    try std.testing.expect(!policy.glyphAtlasDecodeSlot(-1, &slot));
    try std.testing.expectEqual(@as(c_int, 123), slot.index);
    try std.testing.expectEqual(@as(c_int, 2), slot.width);
    try std.testing.expect(slot.color);
}

test "glyph cell placement advances by decoded width" {
    var next_cell: c_int = -1;
    try std.testing.expect(policy.glyphAtlasAdvanceCells(0, 2, 4, &next_cell));
    try std.testing.expectEqual(@as(c_int, 2), next_cell);
    try std.testing.expect(policy.glyphAtlasAdvanceCells(
        next_cell,
        1,
        4,
        &next_cell,
    ));
    try std.testing.expectEqual(@as(c_int, 3), next_cell);

    try std.testing.expect(!policy.glyphAtlasAdvanceCells(
        next_cell,
        2,
        4,
        &next_cell,
    ));
    try std.testing.expectEqual(@as(c_int, 3), next_cell);
}
