#include "glyph_cache_policy.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

static bool isPowerOfTwo(uint32_t value) {
    return value != 0 && (value & (value - 1)) == 0;
}

static void clearEntries(GlyphMapEntry* entries, uint32_t capacity) {
    for (uint32_t i = 0; i < capacity; i++) entries[i].slot = -1;
}

static uint32_t mapIndex(uint32_t codepoint, uint32_t capacity) {
    return (codepoint * 2654435761u) & (capacity - 1);
}

static bool insertEntry(GlyphMapEntry* entries, uint32_t capacity,
                        uint32_t codepoint, int slot, bool* inserted) {
    uint32_t start = mapIndex(codepoint, capacity);
    for (uint32_t probe = 0; probe < capacity; probe++) {
        uint32_t index = (start + probe) & (capacity - 1);
        if (entries[index].slot < 0) {
            entries[index].codepoint = codepoint;
            entries[index].slot = slot;
            *inserted = true;
            return true;
        }
        if (entries[index].codepoint == codepoint) {
            entries[index].slot = slot;
            *inserted = false;
            return true;
        }
    }
    return false;
}

uint32_t glyphMapCapacityForEntries(uint32_t entry_capacity) {
    uint64_t required = ((uint64_t)entry_capacity * 10u + 6u) / 7u;
    uint32_t capacity = 8;
    while ((uint64_t)capacity < required) {
        if (capacity > UINT32_MAX / 2u) return 0;
        capacity *= 2u;
    }
    return capacity;
}

bool glyphMapInit(GlyphMap* map, uint32_t initial_capacity,
                  uint32_t max_capacity) {
    if (!map || !isPowerOfTwo(initial_capacity)
            || !isPowerOfTwo(max_capacity)
            || initial_capacity > max_capacity) {
        return false;
    }

    GlyphMapEntry* entries = calloc(initial_capacity, sizeof(GlyphMapEntry));
    if (!entries) return false;
    clearEntries(entries, initial_capacity);

    map->entries = entries;
    map->capacity = initial_capacity;
    map->count = 0;
    map->max_capacity = max_capacity;
    return true;
}

void glyphMapDeinit(GlyphMap* map) {
    if (!map) return;
    free(map->entries);
    memset(map, 0, sizeof(*map));
}

int glyphMapLookup(const GlyphMap* map, uint32_t codepoint) {
    if (!map || !map->entries || map->capacity == 0) return -1;

    uint32_t start = mapIndex(codepoint, map->capacity);
    for (uint32_t probe = 0; probe < map->capacity; probe++) {
        uint32_t index = (start + probe) & (map->capacity - 1);
        if (map->entries[index].slot < 0) return -1;
        if (map->entries[index].codepoint == codepoint)
            return map->entries[index].slot;
    }
    return -1;
}

bool glyphMapPrepareInsert(GlyphMap* map, uint32_t codepoint) {
    if (!map || !map->entries || map->capacity == 0) return false;
    if (glyphMapLookup(map, codepoint) >= 0) return true;

    uint64_t next_load = (uint64_t)(map->count + 1u) * 10u;
    uint64_t load_limit = (uint64_t)map->capacity * 7u;
    if (next_load <= load_limit) return true;
    if (map->capacity >= map->max_capacity) return false;

    uint32_t new_capacity = map->capacity * 2u;
    if (new_capacity < map->capacity || new_capacity > map->max_capacity)
        new_capacity = map->max_capacity;

    GlyphMapEntry* new_entries = calloc(new_capacity, sizeof(GlyphMapEntry));
    if (!new_entries) return false;
    clearEntries(new_entries, new_capacity);

    for (uint32_t i = 0; i < map->capacity; i++) {
        if (map->entries[i].slot < 0) continue;
        bool inserted = false;
        if (!insertEntry(new_entries, new_capacity,
                         map->entries[i].codepoint, map->entries[i].slot,
                         &inserted)) {
            free(new_entries);
            return false;
        }
    }

    GlyphMapEntry* old_entries = map->entries;
    map->entries = new_entries;
    map->capacity = new_capacity;
    free(old_entries);
    return true;
}

bool glyphMapInsertPrepared(GlyphMap* map, uint32_t codepoint, int slot) {
    if (!map || !map->entries || map->capacity == 0 || slot < 0) return false;

    bool inserted = false;
    if (!insertEntry(map->entries, map->capacity, codepoint, slot, &inserted))
        return false;
    if (inserted) map->count++;
    return true;
}

bool glyphAtlasInitialGeometry(int glyph_width, int glyph_height,
                               int max_texture_dimension,
                               GlyphAtlasGeometry* geometry) {
    if (!geometry || glyph_width <= 0 || glyph_height <= 0
            || max_texture_dimension <= 0
            || glyph_width > max_texture_dimension
            || glyph_height > max_texture_dimension) {
        return false;
    }

    int cols = max_texture_dimension / glyph_width;
    if (cols > GLYPH_ATLAS_DEFAULT_COLS) cols = GLYPH_ATLAS_DEFAULT_COLS;
    int max_rows = max_texture_dimension / glyph_height;
    int rows = max_rows;
    if (rows > GLYPH_ATLAS_DEFAULT_ROWS) rows = GLYPH_ATLAS_DEFAULT_ROWS;
    if (cols < 2 || rows <= 0 || max_rows <= 0) return false;

    int64_t width = (int64_t)glyph_width * cols;
    int64_t height = (int64_t)glyph_height * rows;
    int64_t max_slots = (int64_t)cols * max_rows;
    if (width <= 0 || width > max_texture_dimension
            || height <= 0 || height > max_texture_dimension
            || max_slots <= 0 || max_slots > INT_MAX) {
        return false;
    }

    GlyphAtlasGeometry result = {
        .cols = cols,
        .rows = rows,
        .width = (int)width,
        .height = (int)height,
        .max_rows = max_rows,
        .max_slots = (int)max_slots,
    };
    *geometry = result;
    return true;
}

int glyphAtlasWidePadding(int next_slot, int atlas_cols) {
    if (next_slot < 0 || atlas_cols <= 0) return 0;
    return next_slot % atlas_cols == atlas_cols - 1 ? 1 : 0;
}

bool glyphAtlasPlanGrowth(int atlas_cols, int glyph_height, int current_rows,
                          int next_slot, int requested_slots,
                          int max_texture_height, GlyphAtlasGrowth* growth) {
    if (!growth || atlas_cols <= 0 || glyph_height <= 0 || current_rows <= 0
            || next_slot < 0 || requested_slots <= 0
            || max_texture_height <= 0) {
        return false;
    }

    int max_rows = max_texture_height / glyph_height;
    if (max_rows <= 0 || current_rows > max_rows) return false;

    int64_t required_slots = (int64_t)next_slot + requested_slots;
    int64_t final_slots = (int64_t)atlas_cols * max_rows;
    if (required_slots <= 0 || required_slots > final_slots) return false;

    int64_t required_rows =
        (required_slots + atlas_cols - 1) / atlas_cols;
    int new_rows = current_rows;
    while ((int64_t)new_rows < required_rows) {
        if (new_rows >= max_rows) return false;
        if (new_rows > max_rows / 2)
            new_rows = max_rows;
        else
            new_rows *= 2;
    }

    int64_t height = (int64_t)glyph_height * new_rows;
    int64_t max_slots = (int64_t)atlas_cols * new_rows;
    if (height <= 0 || height > max_texture_height
            || max_slots <= 0 || max_slots > INT_MAX) {
        return false;
    }

    GlyphAtlasGrowth result = {
        .rows = new_rows,
        .height = (int)height,
        .max_slots = (int)max_slots,
    };
    *growth = result;
    return true;
}

bool glyphAtlasPixelBytes(int width, int height, int bytes_per_pixel,
                          size_t* byte_count) {
    if (!byte_count || width <= 0 || height <= 0 || bytes_per_pixel <= 0)
        return false;

    size_t width_value = (size_t)width;
    size_t height_value = (size_t)height;
    size_t bytes_value = (size_t)bytes_per_pixel;
    if (width_value > SIZE_MAX / height_value) return false;
    size_t pixels = width_value * height_value;
    if (pixels > SIZE_MAX / bytes_value) return false;

    *byte_count = pixels * bytes_value;
    return true;
}
