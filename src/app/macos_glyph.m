// Attyx — macOS glyph cache (Core Text rasterization)

#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#include <string.h>
#include <stdlib.h>
#include "macos_internal.h"

// Font matching helpers (defined in macos_font.m)
extern CTFontRef createVerifiedFont(CFStringRef reqName, CGFloat fontSize);
extern CTFontRef createFuzzyMatchFont(CFStringRef reqName, CGFloat fontSize);

// createGlyphCache() and reference cell statics are in macos_font.m.

/// Returns true if `cp` belongs to a Unicode range whose East Asian Width
/// property is W (Wide) or F (Fullwidth) — i.e. it occupies 2 terminal cells.
/// Characters with EAW = N / Na / H must return false even if the font
/// happens to draw them wider than one cell (e.g. regional indicators).
int glyphCacheRasterize(GlyphCache* gc, uint32_t cp) {
    int gw = (int)gc->glyph_w;
    int gh = (int)gc->glyph_h;

    // Extract style bits and base codepoint from the key.
    int styleBold   = (cp & GLYPH_BOLD_BIT)   ? 1 : 0;
    int styleItalic = (cp & GLYPH_ITALIC_BIT)  ? 1 : 0;
    uint32_t baseCp = cp & 0x1FFFFF;

    // 1. UTF-16 encoding
    UniChar utf16[2];
    int utf16Len;
    if (baseCp <= 0xFFFF) {
        utf16[0] = (UniChar)baseCp;
        utf16Len = 1;
    } else {
        uint32_t u = baseCp - 0x10000;
        utf16[0] = (UniChar)(0xD800 + (u >> 10));
        utf16[1] = (UniChar)(0xDC00 + (u & 0x3FF));
        utf16Len = 2;
    }

    // 2. Select styled font, then glyph lookup: styled font → primary → fallbacks
    CTFontRef styledFont = gc->font;
    if (styleBold && styleItalic)      styledFont = gc->font_bold_italic;
    else if (styleBold)                styledFont = gc->font_bold;
    else if (styleItalic)              styledFont = gc->font_italic;
    CTFontRef drawFont = styledFont;
    CGGlyph glyph = 0;
    bool haveGlyph = CTFontGetGlyphsForCharacters(styledFont, utf16, &glyph, utf16Len)
                  && glyph != 0;
    if (!haveGlyph) {
        CGFloat fontSize = CTFontGetSize(gc->font);
        CTFontRef found = NULL;
        for (int fi = 0; fi < g_font_fallback_count; fi++) {
            CFStringRef name = CFStringCreateWithCString(NULL, g_font_fallback[fi],
                                                         kCFStringEncodingUTF8);
            CTFontRef candidate = createVerifiedFont(name, fontSize);
            if (!candidate) candidate = createFuzzyMatchFont(name, fontSize);
            CFRelease(name);
            if (candidate) {
                if (CTFontGetGlyphsForCharacters(candidate, utf16, &glyph, utf16Len)) {
                    found = candidate;
                    haveGlyph = true;
                    break;
                }
                CFRelease(candidate);
            }
        }
        if (found) {
            drawFont = found;
        } else {
            NSString* str = [[NSString alloc] initWithCharacters:utf16 length:utf16Len];
            CTFontRef fallback = CTFontCreateForString(gc->font, (__bridge CFStringRef)str,
                                                        CFRangeMake(0, str.length));
            if (fallback) {
                if (CTFontGetGlyphsForCharacters(fallback, utf16, &glyph, utf16Len)) {
                    drawFont = fallback;
                    haveGlyph = true;
                } else {
                    CFRelease(fallback);
                }
            }
        }
    }

    // 3. Classify: detect wide glyphs (advance or ink > 1.05× cell width).
    //    Wide glyphs get a 2-cell atlas slot and a 2×gw wide renderer quad.
    //    We measure any non-Latin glyph (>= U+0100) — the 1.05× threshold
    //    prevents false positives from slightly-wider regular glyphs, while
    //    ensuring symbols like ⌘ (U+2318) from Nerd Fonts aren't clipped.
    bool isPowerline = (baseCp >= 0xE0B0 && baseCp <= 0xE0D4);
    bool isBoxDraw   = (baseCp >= 0x2500 && baseCp <= 0x257F);
    bool isBlock     = (baseCp >= 0x2580 && baseCp <= 0x259F);
    bool wide = false;
    if (haveGlyph && !isPowerline && !isBlock && baseCp >= 0x100) {
        CGRect bbox;
        CTFontGetBoundingRectsForGlyphs(drawFont, kCTFontOrientationDefault, &glyph, &bbox, 1);
        CGSize adv;
        CTFontGetAdvancesForGlyphs(drawFont, kCTFontOrientationDefault, &glyph, &adv, 1);
        float inkRight = (float)(bbox.origin.x + bbox.size.width);
        float srcW = fmaxf((float)adv.width, inkRight);
        wide = (srcW > (float)gw * 1.05f);
    }
    int renderW = wide ? 2 * gw : gw;

    int glyphSlots = wide ? 2 : 1;
    int rowPadding = wide
        ? glyphAtlasWidePadding(gc->next_slot, gc->atlas_cols)
        : 0;
    if (!glyphCachePrepareInsert(gc, cp)
            || !glyphCacheReserveSlots(gc, rowPadding + glyphSlots)) {
        if (drawFont != gc->font && drawFont != gc->font_bold
                && drawFont != gc->font_italic
                && drawFont != gc->font_bold_italic)
            CFRelease(drawFont);
        return glyphCacheFallbackSlot(gc);
    }
    int slot = gc->next_slot + rowPadding;
    int ac = slot % gc->atlas_cols;
    int ar = slot / gc->atlas_cols;

    // 5. If no glyph was found, store a blank slot (all-zero pixels) and return.
    //    Block elements skip this: they are drawn as geometry, no glyph needed.
    if (!haveGlyph && !isBlock) {
        if (drawFont != gc->font && drawFont != gc->font_bold
                && drawFont != gc->font_italic && drawFont != gc->font_bold_italic)
                CFRelease(drawFont);
        if (!glyphCacheInsert(gc, cp, slot)) return glyphCacheFallbackSlot(gc);
        gc->next_slot = slot + glyphSlots;
        return slot;
    }

    // 5b. Color emoji path: detect Apple Color Emoji and rasterize into BGRA color atlas.
    if (haveGlyph && !isBlock) {
        CFStringRef familyName = CTFontCopyFamilyName(drawFont);
        bool isColorEmoji = (CFStringCompare(familyName, CFSTR("Apple Color Emoji"), 0)
                             == kCFCompareEqualTo);
        CFRelease(familyName);

        if (isColorEmoji) {
            size_t pixelBytes = 0;
            if (!glyphCacheEnsureColorTexture(gc)
                    || !glyphAtlasPixelBytes(renderW, gh, 4, &pixelBytes)) {
                if (drawFont != gc->font && drawFont != gc->font_bold
                        && drawFont != gc->font_italic
                        && drawFont != gc->font_bold_italic)
                    CFRelease(drawFont);
                return glyphCacheFallbackSlot(gc);
            }

            CGColorSpaceRef rgbCS = CGColorSpaceCreateDeviceRGB();
            uint8_t* pixels = calloc(pixelBytes, 1);
            CGContextRef ctx = NULL;
            if (pixels && rgbCS) {
                ctx = CGBitmapContextCreate(
                    pixels, renderW, gh, 8, renderW * 4, rgbCS,
                    kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst);
            }
            if (rgbCS) CGColorSpaceRelease(rgbCS);
            if (!pixels || !ctx) {
                if (ctx) CGContextRelease(ctx);
                free(pixels);
                if (drawFont != gc->font && drawFont != gc->font_bold
                        && drawFont != gc->font_italic
                        && drawFont != gc->font_bold_italic)
                    CFRelease(drawFont);
                return glyphCacheFallbackSlot(gc);
            }

            NSString* str = [[NSString alloc] initWithCharacters:utf16 length:utf16Len];
            NSDictionary* attrs = @{(NSString*)kCTFontAttributeName: (__bridge id)drawFont};
            NSAttributedString* attrStr = [[NSAttributedString alloc]
                initWithString:str attributes:attrs];
            CTLineRef line = CTLineCreateWithAttributedString(
                (__bridge CFAttributedStringRef)attrStr);
            float posX = wide ? 0.0f : (float)gc->x_offset;
            CGContextSetTextPosition(ctx, (CGFloat)posX, (CGFloat)gc->baseline_y);
            CTLineDraw(line, ctx);
            CFRelease(line);
            CGContextRelease(ctx);

            int encoded = (wide ? GLYPH_WIDE_BIT : 0) | GLYPH_COLOR_BIT | slot;
            if (!glyphCacheInsert(gc, cp, encoded)) {
                free(pixels);
                if (drawFont != gc->font && drawFont != gc->font_bold
                        && drawFont != gc->font_italic
                        && drawFont != gc->font_bold_italic)
                    CFRelease(drawFont);
                return glyphCacheFallbackSlot(gc);
            }
            [gc->color_texture
                replaceRegion:MTLRegionMake2D(ac * gw, ar * gh, renderW, gh)
                  mipmapLevel:0 withBytes:pixels bytesPerRow:(NSUInteger)(renderW * 4)];
            free(pixels);
            gc->next_slot = slot + glyphSlots;

            if (drawFont != gc->font && drawFont != gc->font_bold
                && drawFont != gc->font_italic && drawFont != gc->font_bold_italic)
                CFRelease(drawFont);
            return encoded;
        }
    }

    // 6. Create bitmap context (renderW × gh)
    size_t pixelBytes = 0;
    if (!glyphAtlasPixelBytes(renderW, gh, 1, &pixelBytes)) {
        if (drawFont != gc->font && drawFont != gc->font_bold
                && drawFont != gc->font_italic
                && drawFont != gc->font_bold_italic)
            CFRelease(drawFont);
        return glyphCacheFallbackSlot(gc);
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    uint8_t* pixels = calloc(pixelBytes, 1);
    CGContextRef ctx = NULL;
    if (pixels && cs) {
        ctx = CGBitmapContextCreate(pixels, renderW, gh, 8, renderW, cs,
                                    kCGImageAlphaNone);
    }
    if (cs) CGColorSpaceRelease(cs);
    if (!pixels || !ctx) {
        if (ctx) CGContextRelease(ctx);
        free(pixels);
        if (drawFont != gc->font && drawFont != gc->font_bold
                && drawFont != gc->font_italic
                && drawFont != gc->font_bold_italic)
            CFRelease(drawFont);
        return glyphCacheFallbackSlot(gc);
    }
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    // Disable LCD subpixel smoothing — it fattens strokes in grayscale contexts.
    CGContextSetShouldSmoothFonts(ctx, NO);
    CGContextSetAllowsFontSmoothing(ctx, NO);

    // 7. Draw glyph into the bitmap
    if (isBoxDraw) {
        // Box-drawing (U+2500–U+257F): geometry-based rendering for pixel-perfect
        // thin lines at exactly 1 logical pixel — no font metrics involved.
        // Falls back to unscaled glyph draw for dashed/arc variants not in the table.
        if (!renderBoxDraw(ctx, baseCp, gw, gh, gc->scale)) {
            CGPoint pos = CGPointMake((float)gc->x_offset, gc->baseline_y);
            CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
        }
    } else if (isPowerline) {
        // Powerline glyphs (U+E0B0–U+E0D4): scale to fill the full cell so that
        // chevrons and hard-separators tile seamlessly regardless of cell height.
        CGSize adv;
        CTFontGetAdvancesForGlyphs(drawFont, kCTFontOrientationDefault, &glyph, &adv, 1);
        CGFloat asc  = CTFontGetAscent(drawFont);
        CGFloat desc = CTFontGetDescent(drawFont);
        CGFloat srcW = (adv.width > 1) ? adv.width : (CGFloat)gw;
        CGFloat srcH = asc + desc;
        if (srcH < 1) srcH = (CGFloat)gh;
        float sx = (float)gw / (float)srcW;
        float sy = (float)gh / (float)srcH;
        CGContextScaleCTM(ctx, sx, sy);
        CGPoint pos = CGPointMake(0.0f, (float)desc);
        CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
    } else if (isBlock) {
        // Render block/quadrant elements as pure geometry for pixel-perfect results.
        // Font-glyph bounding-box scaling doesn't preserve partial fills:
        // scaling ▄ (bbox height = gh/2) by gh/bbox.height = 2× yields a full block.
        // CG coordinate system: y=0 at bottom of context.
        bool drawn = false;
        if (baseCp >= 0x2581 && baseCp <= 0x2588) {
            // LOWER ONE-EIGHTH .. FULL BLOCK (U+2581–U+2588)
            int eighths = (int)(baseCp - 0x2580); // 1..8
            float blockH = roundf((float)gh * eighths / 8.0f);
            CGContextFillRect(ctx, CGRectMake(0, 0, (float)gw, blockH));
            drawn = true;
        } else if (baseCp == 0x2580) {
            // UPPER HALF BLOCK
            float halfH = roundf((float)gh / 2.0f);
            CGContextFillRect(ctx, CGRectMake(0, (float)gh - halfH, (float)gw, halfH));
            drawn = true;
        } else if (baseCp >= 0x2589 && baseCp <= 0x258F) {
            // LEFT SEVEN-EIGHTHS .. LEFT ONE-EIGHTH BLOCK (U+2589–U+258F)
            int eighths = (int)(0x2590 - baseCp); // 7..1
            float blockW = roundf((float)gw * eighths / 8.0f);
            CGContextFillRect(ctx, CGRectMake(0, 0, blockW, (float)gh));
            drawn = true;
        } else if (baseCp == 0x2590) {
            // RIGHT HALF BLOCK
            float halfW = roundf((float)gw / 2.0f);
            CGContextFillRect(ctx, CGRectMake((float)gw - halfW, 0, halfW, (float)gh));
            drawn = true;
        } else if (baseCp == 0x2594) {
            // UPPER ONE EIGHTH BLOCK
            float blockH = roundf((float)gh / 8.0f);
            CGContextFillRect(ctx, CGRectMake(0, (float)gh - blockH, (float)gw, blockH));
            drawn = true;
        } else if (baseCp == 0x2595) {
            // RIGHT ONE EIGHTH BLOCK
            float blockW = roundf((float)gw / 8.0f);
            CGContextFillRect(ctx, CGRectMake((float)gw - blockW, 0, blockW, (float)gh));
            drawn = true;
        } else if (baseCp >= 0x2591 && baseCp <= 0x2593) {
            // SHADE CHARACTERS — render as solid fills at fractional brightness.
            // ░ = 25%, ▒ = 50%, ▓ = 75%
            static const float shadeAlpha[] = {0.25f, 0.50f, 0.75f};
            float a = shadeAlpha[baseCp - 0x2591];
            CGContextSetGrayFillColor(ctx, 1.0f, a);
            CGContextFillRect(ctx, CGRectMake(0, 0, (float)gw, (float)gh));
            CGContextSetGrayFillColor(ctx, 1.0f, 1.0f); // restore
            drawn = true;
        } else if (baseCp >= 0x2596 && baseCp <= 0x259F) {
            // QUADRANT BLOCKS — bits: UL=1, UR=2, BL=4, BR=8
            static const int quadBits[] = {4, 8, 1, 13, 9, 7, 11, 2, 6, 14};
            int bits = quadBits[baseCp - 0x2596];
            float hw = roundf((float)gw / 2.0f);
            float hh = roundf((float)gh / 2.0f);
            if (bits & 1) CGContextFillRect(ctx, CGRectMake(0,  hh, hw,            (float)gh - hh)); // UL
            if (bits & 2) CGContextFillRect(ctx, CGRectMake(hw, hh, (float)gw - hw, (float)gh - hh)); // UR
            if (bits & 4) CGContextFillRect(ctx, CGRectMake(0,  0,  hw,            hh));              // BL
            if (bits & 8) CGContextFillRect(ctx, CGRectMake(hw, 0,  (float)gw - hw, hh));             // BR
            drawn = true;
        }
        if (!drawn && haveGlyph) {
            // Shade characters (U+2591–U+2593) and other unhandled block chars:
            // fall back to bbox-scaled glyph (they fill the full cell so scaling is fine).
            CGRect bbox;
            CTFontGetBoundingRectsForGlyphs(drawFont, kCTFontOrientationDefault, &glyph, &bbox, 1);
            if (bbox.size.width > 1 && bbox.size.height > 1) {
                float sx = (float)gw / (float)bbox.size.width;
                float sy = (float)gh / (float)bbox.size.height;
                CGContextScaleCTM(ctx, sx, sy);
                CGPoint pos = CGPointMake(-bbox.origin.x, -bbox.origin.y);
                CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
            } else {
                CGPoint pos = CGPointMake(gc->x_offset, gc->baseline_y);
                CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
            }
        }
    } else if (wide) {
        // Wide icon: draw at natural origin in the 2×gw context — no scaling needed.
        // The glyph's advance fills the wider slot; the renderer quad spans 2 cells.
        CGPoint pos = CGPointMake(0.0f, gc->baseline_y);
        CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
    } else {
        // Normal glyph: fits within one cell.
        // Check if the glyph's ink overflows the cell. If so, scale it down uniformly to fit.
        CGRect bbox;
        CTFontGetBoundingRectsForGlyphs(drawFont, kCTFontOrientationDefault, &glyph, &bbox, 1);
        float inkL = gc->x_offset + (float)bbox.origin.x;
        float inkR = inkL + (float)bbox.size.width;
        float inkB = gc->baseline_y + (float)bbox.origin.y;
        float inkT = inkB + (float)bbox.size.height;
        bool overflows = (inkR > (float)gw + 0.5f) || (inkT > (float)gh + 0.5f) ||
                         (inkL < -0.5f) || (inkB < -0.5f);
        if (overflows && bbox.size.width > 0.5 && bbox.size.height > 0.5) {
            float sx = (float)gw / (float)bbox.size.width;
            float sy = (float)gh / (float)bbox.size.height;
            float s  = fminf(sx, sy);
            if (s > 1.0f) s = 1.0f;
            CGContextScaleCTM(ctx, s, s);
            // Center the scaled glyph in the cell
            float posX = ((float)gw / s - (float)bbox.size.width) * 0.5f - (float)bbox.origin.x;
            float posY = ((float)gh / s - (float)bbox.size.height) * 0.5f - (float)bbox.origin.y;
            CGPoint pos = CGPointMake(posX, posY);
            CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
        } else {
            CGPoint pos = CGPointMake(gc->x_offset, gc->baseline_y);
            CTFontDrawGlyphs(drawFont, &glyph, &pos, 1, ctx);
        }
    }

    CGContextRelease(ctx);
    if (drawFont != gc->font && drawFont != gc->font_bold
                && drawFont != gc->font_italic && drawFont != gc->font_bold_italic)
                CFRelease(drawFont);

    int encoded = wide ? (slot | GLYPH_WIDE_BIT) : slot;
    if (!glyphCacheInsert(gc, cp, encoded)) {
        free(pixels);
        return glyphCacheFallbackSlot(gc);
    }
    [gc->texture replaceRegion:MTLRegionMake2D(ac * gw, ar * gh, renderW, gh)
                   mipmapLevel:0
                     withBytes:pixels
                   bytesPerRow:renderW];
    free(pixels);
    gc->next_slot = slot + glyphSlots;

    return encoded;
}

// ---------------------------------------------------------------------------
// Combining mark support
// ---------------------------------------------------------------------------

uint32_t combiningKey(uint32_t base, uint32_t c1, uint32_t c2) {
    uint32_t h = base ^ (c1 * 0x9e3779b9) ^ (c2 * 0x517cc1b7);
    return (h & 0x7FFFFFFF) | 0x80000000; // high bit distinguishes from plain codepoints
}

/// Encode a codepoint as UTF-16 into buf. Returns number of UniChar units written.
static int cpToUtf16(uint32_t cp, UniChar buf[2]) {
    if (cp <= 0xFFFF) { buf[0] = (UniChar)cp; return 1; }
    uint32_t u = cp - 0x10000;
    buf[0] = (UniChar)(0xD800 + (u >> 10));
    buf[1] = (UniChar)(0xDC00 + (u & 0x3FF));
    return 2;
}

int glyphCacheRasterizeCombined(GlyphCache* gc, uint32_t base, uint32_t c1, uint32_t c2) {
    int gw = (int)gc->glyph_w;
    int gh = (int)gc->glyph_h;
    uint32_t key = combiningKey(base, c1, c2);

    // 1. Font fallback for the base character (same chain as regular rasterizer)
    UniChar baseUtf16[2];
    int baseLen = cpToUtf16(base, baseUtf16);

    CTFontRef drawFont = gc->font;
    bool ownFont = false;
    CGGlyph baseGlyph = 0;
    bool haveGlyph = CTFontGetGlyphsForCharacters(gc->font, baseUtf16, &baseGlyph, baseLen)
                  && baseGlyph != 0;
    if (!haveGlyph) {
        CGFloat fontSize = CTFontGetSize(gc->font);
        CTFontRef found = NULL;
        for (int fi = 0; fi < g_font_fallback_count; fi++) {
            CFStringRef name = CFStringCreateWithCString(NULL, g_font_fallback[fi],
                                                         kCFStringEncodingUTF8);
            CTFontRef candidate = createVerifiedFont(name, fontSize);
            if (!candidate) candidate = createFuzzyMatchFont(name, fontSize);
            CFRelease(name);
            if (candidate) {
                if (CTFontGetGlyphsForCharacters(candidate, baseUtf16, &baseGlyph, baseLen)) {
                    found = candidate;
                    haveGlyph = true;
                    break;
                }
                CFRelease(candidate);
            }
        }
        if (found) {
            drawFont = found;
            ownFont = true;
        } else {
            // System fallback via full string
            UniChar fullUtf16[6];
            int fullLen = 0;
            uint32_t cps[3] = { base, c1, c2 };
            for (int i = 0; i < 3; i++) {
                if (cps[i] == 0) continue;
                fullLen += cpToUtf16(cps[i], &fullUtf16[fullLen]);
            }
            NSString* fullStr = [[NSString alloc] initWithCharacters:fullUtf16 length:fullLen];
            CTFontRef fallback = CTFontCreateForString(gc->font, (__bridge CFStringRef)fullStr,
                                                        CFRangeMake(0, fullStr.length));
            if (fallback) {
                if (CTFontGetGlyphsForCharacters(fallback, baseUtf16, &baseGlyph, baseLen))
                    haveGlyph = true;
                drawFont = fallback;
                ownFont = true;
            }
        }
    }

    if (!glyphCachePrepareInsert(gc, key) || !glyphCacheReserveSlots(gc, 1)) {
        if (ownFont) CFRelease(drawFont);
        return glyphCacheFallbackSlot(gc);
    }
    int slot = gc->next_slot;
    int ac = slot % gc->atlas_cols;
    int ar = slot / gc->atlas_cols;

    if (!haveGlyph) {
        if (ownFont) CFRelease(drawFont);
        if (!glyphCacheInsert(gc, key, slot)) return glyphCacheFallbackSlot(gc);
        gc->next_slot++;
        return slot;
    }

    size_t pixelBytes = 0;
    if (!glyphAtlasPixelBytes(gw, gh, 1, &pixelBytes)) {
        if (ownFont) CFRelease(drawFont);
        return glyphCacheFallbackSlot(gc);
    }
    uint8_t* pixels = calloc(pixelBytes, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = NULL;
    if (pixels && cs)
        ctx = CGBitmapContextCreate(pixels, gw, gh, 8, gw, cs, kCGImageAlphaNone);
    if (cs) CGColorSpaceRelease(cs);
    if (!pixels || !ctx) {
        if (ctx) CGContextRelease(ctx);
        free(pixels);
        if (ownFont) CFRelease(drawFont);
        return glyphCacheFallbackSlot(gc);
    }
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    CGContextSetShouldSmoothFonts(ctx, NO);
    CGContextSetAllowsFontSmoothing(ctx, NO);

    // 4. Draw base glyph at cell origin — identical to regular rasterizer path.
    //    This is proven to work for Thai characters.
    CGPoint pos = CGPointMake(gc->x_offset, gc->baseline_y);
    CTFontDrawGlyphs(drawFont, &baseGlyph, &pos, 1, ctx);

    // 5. Overlay combining marks at the same position.
    //    The font's glyph metrics handle vertical placement (above/below base).
    uint32_t marks[2] = { c1, c2 };
    for (int m = 0; m < 2; m++) {
        if (marks[m] == 0) continue;
        UniChar markUtf16[2];
        int markLen = cpToUtf16(marks[m], markUtf16);
        CGGlyph markGlyph = 0;
        if (CTFontGetGlyphsForCharacters(drawFont, markUtf16, &markGlyph, markLen)
            && markGlyph != 0) {
            CTFontDrawGlyphs(drawFont, &markGlyph, &pos, 1, ctx);
        }
    }

    CGContextRelease(ctx);
    if (ownFont) CFRelease(drawFont);

    if (!glyphCacheInsert(gc, key, slot)) {
        free(pixels);
        return glyphCacheFallbackSlot(gc);
    }
    [gc->texture replaceRegion:MTLRegionMake2D(ac * gw, ar * gh, gw, gh)
                   mipmapLevel:0
                     withBytes:pixels
                   bytesPerRow:gw];
    free(pixels);
    gc->next_slot++;

    return slot;
}

// createGlyphCache() is defined in macos_font.m
