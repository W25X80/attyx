#import <CoreText/CoreText.h>
#import <Metal/Metal.h>

#include <stdlib.h>
#include "macos_internal.h"

static void glyphCacheWarnOnce(GlyphCache* gc, NSString* reason) {
    if (gc->capacity_warning_emitted) return;
    gc->capacity_warning_emitted = true;
    NSLog(@"[attyx] glyph cache capacity exhausted: %@", reason);
}

static id<MTLTexture> createClearedTexture(id<MTLDevice> device,
                                           MTLPixelFormat format,
                                           int width, int height,
                                           int bytes_per_pixel) {
    size_t byte_count = 0;
    if (!device || !glyphAtlasPixelBytes(width, height, bytes_per_pixel,
                                          &byte_count)) {
        return nil;
    }

    uint8_t* zeroes = calloc(byte_count, 1);
    if (!zeroes) return nil;

    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:(NSUInteger)width
                                                          height:(NSUInteger)height
                                                       mipmapped:NO];
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (texture) {
        [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                   mipmapLevel:0
                     withBytes:zeroes
                   bytesPerRow:(NSUInteger)(width * bytes_per_pixel)];
    }
    free(zeroes);
    return texture;
}

static void setDisabledStorage(GlyphCache* gc) {
    gc->texture = createClearedTexture(gc->device, MTLPixelFormatR8Unorm,
                                       1, 1, 1);
    gc->color_texture = nil;
    gc->atlas_cols = 1;
    gc->atlas_w = 1;
    gc->atlas_h = 1;
    gc->atlas_rows = 1;
    gc->max_atlas_rows = 1;
    gc->next_slot = 0;
    gc->max_slots = 1;
    gc->fallback_slot = 0;
    gc->storage_valid = false;

    if (!gc->map.entries) glyphMapInit(&gc->map, 8, 8);
}

bool glyphCacheInitStorage(GlyphCache* gc) {
    if (!gc) return false;

    gc->fallback_slot = 0;
    gc->capacity_warning_emitted = false;

    GlyphAtlasGeometry geometry;
    if (!glyphAtlasInitialGeometry((int)gc->glyph_w, (int)gc->glyph_h,
                                   GLYPH_ATLAS_MAX_TEXTURE_DIMENSION,
                                   &geometry)) {
        setDisabledStorage(gc);
        glyphCacheWarnOnce(gc, @"invalid atlas geometry");
        return false;
    }

    uint32_t max_map_capacity =
        glyphMapCapacityForEntries((uint32_t)geometry.max_slots);
    uint32_t initial_map_capacity = GLYPH_MAP_INITIAL_CAPACITY;
    if (initial_map_capacity > max_map_capacity)
        initial_map_capacity = max_map_capacity;
    if (max_map_capacity == 0
            || !glyphMapInit(&gc->map, initial_map_capacity,
                             max_map_capacity)) {
        setDisabledStorage(gc);
        glyphCacheWarnOnce(gc, @"glyph map allocation failed");
        return false;
    }

    id<MTLTexture> texture = createClearedTexture(
        gc->device, MTLPixelFormatR8Unorm,
        geometry.width, geometry.height, 1);
    if (!texture) {
        glyphMapDeinit(&gc->map);
        setDisabledStorage(gc);
        glyphCacheWarnOnce(gc, @"initial Metal texture allocation failed");
        return false;
    }

    gc->texture = texture;
    gc->color_texture = nil;
    gc->atlas_cols = geometry.cols;
    gc->atlas_w = geometry.width;
    gc->atlas_h = geometry.height;
    gc->atlas_rows = geometry.rows;
    gc->max_atlas_rows = geometry.max_rows;
    gc->next_slot = 0;
    gc->max_slots = geometry.cols * geometry.rows;
    gc->storage_valid = true;
    return true;
}

void destroyGlyphCache(GlyphCache* gc) {
    if (!gc) return;

    glyphMapDeinit(&gc->map);
    if (gc->font) CFRelease(gc->font);
    if (gc->font_bold) CFRelease(gc->font_bold);
    if (gc->font_italic) CFRelease(gc->font_italic);
    if (gc->font_bold_italic) CFRelease(gc->font_bold_italic);
    gc->font = NULL;
    gc->font_bold = NULL;
    gc->font_italic = NULL;
    gc->font_bold_italic = NULL;
    gc->texture = nil;
    gc->color_texture = nil;
    gc->device = nil;
    gc->storage_valid = false;
    gc->next_slot = 0;
    gc->max_slots = 0;
}

int glyphCacheLookup(GlyphCache* gc, uint32_t cp) {
    if (!gc) return -1;
    return glyphMapLookup(&gc->map, cp);
}

bool glyphCachePrepareInsert(GlyphCache* gc, uint32_t cp) {
    if (!gc || !gc->storage_valid) return false;
    if (glyphMapPrepareInsert(&gc->map, cp)) return true;
    glyphCacheWarnOnce(gc, @"glyph map reached its allocation limit");
    return false;
}

bool glyphCacheInsert(GlyphCache* gc, uint32_t cp, int slot) {
    if (!gc || !glyphMapInsertPrepared(&gc->map, cp, slot)) {
        if (gc) glyphCacheWarnOnce(gc, @"prepared glyph insertion failed");
        return false;
    }
    return true;
}

int glyphCacheFallbackSlot(const GlyphCache* gc) {
    return gc && gc->fallback_slot >= 0 ? gc->fallback_slot : 0;
}

bool glyphCacheEnsureColorTexture(GlyphCache* gc) {
    if (!gc || !gc->storage_valid) return false;
    if (gc->color_texture) return true;

    id<MTLTexture> color_texture = createClearedTexture(
        gc->device, MTLPixelFormatBGRA8Unorm,
        gc->atlas_w, gc->atlas_h, 4);
    if (!color_texture) {
        glyphCacheWarnOnce(gc, @"color atlas allocation failed");
        return false;
    }
    gc->color_texture = color_texture;
    return true;
}

bool glyphCacheReserveSlots(GlyphCache* gc, int slots) {
    if (!gc || !gc->storage_valid || slots <= 0) return false;
    if (gc->next_slot <= gc->max_slots - slots) return true;

    GlyphAtlasGrowth growth;
    if (!glyphAtlasPlanGrowth(gc->atlas_cols, (int)gc->glyph_h,
                              gc->atlas_rows, gc->next_slot, slots,
                              GLYPH_ATLAS_MAX_TEXTURE_DIMENSION, &growth)) {
        glyphCacheWarnOnce(gc, @"Metal texture height limit reached");
        return false;
    }

    size_t gray_bytes = 0;
    if (!glyphAtlasPixelBytes(gc->atlas_w, growth.height, 1, &gray_bytes)) {
        glyphCacheWarnOnce(gc, @"grayscale atlas size overflow");
        return false;
    }
    uint8_t* gray_pixels = calloc(gray_bytes, 1);
    if (!gray_pixels) {
        glyphCacheWarnOnce(gc, @"grayscale atlas copy allocation failed");
        return false;
    }
    [gc->texture getBytes:gray_pixels
              bytesPerRow:(NSUInteger)gc->atlas_w
               fromRegion:MTLRegionMake2D(0, 0, gc->atlas_w, gc->atlas_h)
              mipmapLevel:0];

    size_t color_bytes = 0;
    uint8_t* color_pixels = NULL;
    if (gc->color_texture) {
        if (!glyphAtlasPixelBytes(gc->atlas_w, growth.height, 4,
                                  &color_bytes)) {
            free(gray_pixels);
            glyphCacheWarnOnce(gc, @"color atlas size overflow");
            return false;
        }
        color_pixels = calloc(color_bytes, 1);
        if (!color_pixels) {
            free(gray_pixels);
            glyphCacheWarnOnce(gc, @"color atlas copy allocation failed");
            return false;
        }
        [gc->color_texture getBytes:color_pixels
                        bytesPerRow:(NSUInteger)(gc->atlas_w * 4)
                         fromRegion:MTLRegionMake2D(0, 0, gc->atlas_w,
                                                   gc->atlas_h)
                        mipmapLevel:0];
    }

    MTLTextureDescriptor* gray_descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:(NSUInteger)gc->atlas_w
                                                          height:(NSUInteger)growth.height
                                                       mipmapped:NO];
    id<MTLTexture> gray_texture =
        [gc->device newTextureWithDescriptor:gray_descriptor];
    id<MTLTexture> color_texture = nil;
    if (gray_texture && gc->color_texture) {
        MTLTextureDescriptor* color_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:(NSUInteger)gc->atlas_w
                                                              height:(NSUInteger)growth.height
                                                           mipmapped:NO];
        color_texture = [gc->device newTextureWithDescriptor:color_descriptor];
    }

    if (!gray_texture || (gc->color_texture && !color_texture)) {
        free(gray_pixels);
        free(color_pixels);
        glyphCacheWarnOnce(gc, @"grown Metal texture allocation failed");
        return false;
    }

    [gray_texture replaceRegion:MTLRegionMake2D(0, 0, gc->atlas_w,
                                                growth.height)
                    mipmapLevel:0
                      withBytes:gray_pixels
                    bytesPerRow:(NSUInteger)gc->atlas_w];
    if (color_texture) {
        [color_texture replaceRegion:MTLRegionMake2D(0, 0, gc->atlas_w,
                                                     growth.height)
                         mipmapLevel:0
                           withBytes:color_pixels
                         bytesPerRow:(NSUInteger)(gc->atlas_w * 4)];
    }
    free(gray_pixels);
    free(color_pixels);

    gc->texture = gray_texture;
    if (color_texture) gc->color_texture = color_texture;
    gc->atlas_h = growth.height;
    gc->atlas_rows = growth.rows;
    gc->max_slots = growth.max_slots;
    return true;
}
