#ifndef ATTYX_GLYPH_CACHE_POLICY_H
#define ATTYX_GLYPH_CACHE_POLICY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define GLYPH_MAP_INITIAL_CAPACITY 4096u
#define GLYPH_ATLAS_DEFAULT_COLS 32
#define GLYPH_ATLAS_DEFAULT_ROWS 32
#define GLYPH_ATLAS_MAX_TEXTURE_DIMENSION 16384
#define GLYPH_ATLAS_MAX_BYTES ((size_t)128u * 1024u * 1024u)
#define GLYPH_ATLAS_AGGREGATE_BYTES_PER_PIXEL 5
#define GLYPH_WIDE_BIT (1 << 30)
#define GLYPH_COLOR_BIT (1 << 29)

typedef struct {
    uint32_t codepoint;
    int slot;
} GlyphMapEntry;

typedef struct {
    GlyphMapEntry* entries;
    uint32_t capacity;
    uint32_t count;
    uint32_t max_capacity;
} GlyphMap;

typedef struct {
    bool tripped;
    bool color_unavailable;
} GlyphCacheFailureLatch;

typedef struct {
    int cols;
    int rows;
    int width;
    int height;
    int max_rows;
    int max_slots;
} GlyphAtlasGeometry;

typedef struct {
    int rows;
    int height;
    int max_slots;
} GlyphAtlasGrowth;

typedef struct {
    int x0;
    int y0;
    int x1;
    int y1;
} GlyphAtlasTexelRect;

typedef struct {
    int index;
    int width;
    bool color;
} GlyphAtlasSlot;

static inline bool glyphAtlasDecodeSlot(
    int encoded_slot, GlyphAtlasSlot* slot
) {
    if (encoded_slot < 0 || !slot) return false;
    GlyphAtlasSlot result = {
        .index = encoded_slot & ~(GLYPH_WIDE_BIT | GLYPH_COLOR_BIT),
        .width = encoded_slot & GLYPH_WIDE_BIT ? 2 : 1,
        .color = (encoded_slot & GLYPH_COLOR_BIT) != 0,
    };
    *slot = result;
    return true;
}

static inline bool glyphAtlasAdvanceCells(
    int current_cell, int glyph_width, int cell_limit, int* next_cell
) {
    if (current_cell < 0 || glyph_width <= 0 || cell_limit < 0
            || !next_cell || current_cell > cell_limit - glyph_width) {
        return false;
    }
    *next_cell = current_cell + glyph_width;
    return true;
}

static inline GlyphAtlasTexelRect glyphAtlasTexelRect(
    int slot, int atlas_cols, int glyph_width, int glyph_height,
    int slot_width
) {
    GlyphAtlasTexelRect rect = {0, 0, 0, 0};
    if (slot < 0 || atlas_cols <= 0 || glyph_width <= 0
            || glyph_height <= 0 || slot_width <= 0) {
        return rect;
    }
    int column = slot % atlas_cols;
    int row = slot / atlas_cols;
    rect.x0 = column * glyph_width;
    rect.y0 = row * glyph_height;
    rect.x1 = (column + slot_width) * glyph_width;
    rect.y1 = (row + 1) * glyph_height;
    return rect;
}

uint32_t glyphMapCapacityForEntries(uint32_t entry_capacity);
bool glyphMapInit(GlyphMap* map, uint32_t initial_capacity, uint32_t max_capacity);
void glyphMapDeinit(GlyphMap* map);
int glyphMapLookup(const GlyphMap* map, uint32_t codepoint);
bool glyphMapPrepareInsert(GlyphMap* map, uint32_t codepoint);
bool glyphMapInsertPrepared(GlyphMap* map, uint32_t codepoint, int slot);

void glyphCacheFailureLatchReset(GlyphCacheFailureLatch* latch);
void glyphCacheFailureLatchTrip(GlyphCacheFailureLatch* latch);
bool glyphCacheFailureLatchAllowsWork(const GlyphCacheFailureLatch* latch);
void glyphCacheFailureLatchMarkColorUnavailable(GlyphCacheFailureLatch* latch);
bool glyphCacheFailureLatchAllowsColorWork(const GlyphCacheFailureLatch* latch);
bool glyphCacheAsciiWarmupCodepoint(int index, uint32_t* codepoint);

bool glyphAtlasInitialGeometry(int glyph_width, int glyph_height,
                               int max_texture_dimension,
                               GlyphAtlasGeometry* geometry);
int glyphAtlasWidePadding(int next_slot, int atlas_cols);
bool glyphAtlasPlanGrowth(int atlas_cols, int glyph_height, int current_rows,
                          int next_slot, int requested_slots,
                          int max_texture_height, GlyphAtlasGrowth* growth);
bool glyphAtlasPixelBytes(int width, int height, int bytes_per_pixel,
                          size_t* byte_count);

#endif
