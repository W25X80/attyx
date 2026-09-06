// Attyx — macOS Metal renderer (MTKViewDelegate)

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CABase.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include "macos_internal.h"
#include "macos_renderer_private.h"

// Live backing scale of the view's window. Single scale source for the
// guard and the rebuild path — window.backingScaleFactor is defined even
// while window.screen is transiently nil during screen transitions.
static CGFloat liveScale(MTKView* view) {
    NSWindow* w = view.window;
    if (w) return w.backingScaleFactor;
    return [NSScreen mainScreen].backingScaleFactor;
}

// ---------------------------------------------------------------------------
// Emit helpers (shared with search bar)
// ---------------------------------------------------------------------------

int emitRect(Vertex* v, int i, float x, float y, float w, float h,
             float r, float g, float b, float a) {
    v[i+0] = (Vertex){ x,   y,   0,0, r,g,b,a };
    v[i+1] = (Vertex){ x+w, y,   0,0, r,g,b,a };
    v[i+2] = (Vertex){ x,   y+h, 0,0, r,g,b,a };
    v[i+3] = (Vertex){ x+w, y,   0,0, r,g,b,a };
    v[i+4] = (Vertex){ x+w, y+h, 0,0, r,g,b,a };
    v[i+5] = (Vertex){ x,   y+h, 0,0, r,g,b,a };
    return i + 6;
}

int emitGlyph(Vertex* v, int i, GlyphCache* gc, uint32_t cp,
              float x, float y, float gw, float gh,
              float r, float g, float b, bool* color) {
    if (color) *color = false;
    int encoded = glyphCacheLookup(gc, cp);
    if (encoded < 0) encoded = glyphCacheRasterize(gc, cp);
    GlyphAtlasSlot slot;
    if (!glyphAtlasDecodeSlot(encoded, &slot)) return i;
    if (color) *color = slot.color;
    float gW = gc->glyph_w, gH = gc->glyph_h;
    GlyphAtlasTexelRect rect = glyphAtlasTexelRect(
        slot.index, gc->atlas_cols, (int)gW, (int)gH, slot.width);
    float u0 = rect.x0, u1 = rect.x1;
    float v0 = rect.y0, v1 = rect.y1;
    float drawW = gw * slot.width;
    if (slot.color) r = g = b = 1.0f;
    v[i+0] = (Vertex){ x,    y,    u0,v0, r,g,b,1 };
    v[i+1] = (Vertex){ x+drawW, y,    u1,v0, r,g,b,1 };
    v[i+2] = (Vertex){ x,    y+gh, u0,v1, r,g,b,1 };
    v[i+3] = (Vertex){ x+drawW, y,    u1,v0, r,g,b,1 };
    v[i+4] = (Vertex){ x+drawW, y+gh, u1,v1, r,g,b,1 };
    v[i+5] = (Vertex){ x,    y+gh, u0,v1, r,g,b,1 };
    return i + 6;
}

int emitString(Vertex* v, int i, GlyphCache* gc,
               const char* str, int len, float x, float y,
               float gw, float gh, float r, float g, float b) {
    for (int c = 0; c < len; c++) {
        uint32_t cp = (uint8_t)str[c];
        if (cp <= 32) continue;
        i = emitGlyph(v, i, gc, cp, x + c * gw, y, gw, gh, r, g, b, NULL);
    }
    return i;
}

// ---------------------------------------------------------------------------
// AttyxRenderer
// ---------------------------------------------------------------------------

@implementation AttyxRenderer

- (instancetype)initWithDevice:(id<MTLDevice>)device
                          view:(MTKView*)view
                    glyphCache:(GlyphCache)glyphCache
{
    self = [super init];
    if (!self) return nil;

    _device     = device;
    _cmdQueue   = [device newCommandQueue];
    _glyphCache = glyphCache;

    _bgVerts          = NULL;
    _textVerts        = NULL;
    _totalTextVerts   = 0;
    _colorVerts       = NULL;
    _totalColorVerts  = 0;
    _bgMetalBuf       = nil;
    _textMetalBuf     = nil;
    _colorMetalBuf    = nil;
    _metalBufCapBg    = 0;
    _metalBufCapText  = 0;
    _metalBufCapColor = 0;
    _cellSnapshot     = NULL;
    _cellSnapshotCap  = 0;
    _prevCursorRow      = -1;
    _prevCursorCol      = -1;
    _prevCursorShape    = -1;
    _prevCursorVisible  = -1;
    _blinkOn            = YES;
    _blinkLastToggle    = CACurrentMediaTime();
    _fullRedrawNeeded   = YES;
    _allocRows          = 0;
    _allocCols          = 0;

    _debugStats       = (getenv("ATTYX_DEBUG_STATS") != NULL);
    _statsFrames      = 0;
    _statsSkipped     = 0;
    _statsDirtyRows   = 0;
    _statsLastPrint   = CFAbsoluteTimeGetCurrent();

    NSError* err = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:kShaderSource
                                              options:nil
                                                error:&err];
    if (!lib) { NSLog(@"Shader error: %@", err); return nil; }

    id<MTLFunction> vertFn    = [lib newFunctionWithName:@"vert_main"];
    id<MTLFunction> fragSolid = [lib newFunctionWithName:@"frag_solid"];
    id<MTLFunction> fragText  = [lib newFunctionWithName:@"frag_text"];

    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction   = vertFn;
        d.fragmentFunction = fragSolid;
        d.colorAttachments[0].pixelFormat     = view.colorPixelFormat;
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        _bgPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_bgPipeline) { NSLog(@"BG pipeline: %@", err); return nil; }
    }

    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction   = vertFn;
        d.fragmentFunction = fragText;
        d.colorAttachments[0].pixelFormat     = view.colorPixelFormat;
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        _textPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_textPipeline) { NSLog(@"Text pipeline: %@", err); return nil; }
    }

    id<MTLFunction> fragColorText = [lib newFunctionWithName:@"frag_color_text"];
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction   = vertFn;
        d.fragmentFunction = fragColorText;
        d.colorAttachments[0].pixelFormat              = view.colorPixelFormat;
        d.colorAttachments[0].blendingEnabled           = YES;
        d.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor    = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        _colorPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_colorPipeline) { NSLog(@"Color pipeline: %@", err); return nil; }
    }

    id<MTLFunction> fragImage = [lib newFunctionWithName:@"frag_image"];
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction   = vertFn;
        d.fragmentFunction = fragImage;
        d.colorAttachments[0].pixelFormat              = view.colorPixelFormat;
        d.colorAttachments[0].blendingEnabled           = YES;
        d.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor    = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        _imagePipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_imagePipeline) { NSLog(@"Image pipeline: %@", err); return nil; }
    }

    _lastImageGen = 0;

    return self;
}

- (void)dealloc {
    destroyGlyphCache(&_glyphCache);
    free(_bgVerts);
    free(_textVerts);
    free(_colorVerts);
    free(_cellSnapshot);
}

- (void)drawInMTKView:(MTKView*)view {
    int rebuild_reason = attyx_take_font_rebuild_reason();
    if (rebuild_reason) {
        [self rebuildFont:view reason:rebuild_reason];
    }
    if (g_needs_window_update) {
        g_needs_window_update = 0;
        attyx_apply_window_update();
    }
    [self drawFrameImpl:view];
    attyx_scrollbar_update();
}

- (void)publishResize:(int)rows cols:(int)cols {
    uint32_t gen = atomic_load_explicit(&g_metrics_gen, memory_order_relaxed);
    atomic_store_explicit(&g_resize_req, attyx_resize_pack(gen, rows, cols),
                          memory_order_release);
}

- (void)rebuildFont:(MTKView*)view reason:(int)reason {
    destroyGlyphCache(&_glyphCache);

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
    // dragging across displays must never resize the window. (The grid may
    // still shift by the per-scale cell_pt pixel-snapping delta; with an
    // integer cell_width override it is preserved exactly.)

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

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
    // Scale-coherence guard: never pair a drawable sized for one screen with
    // glyph metrics rasterized for another. The rebuild path republishes the
    // grid once metrics match (rebuildFont:reason:).
    if (fabs((double)liveScale(view) - (double)_glyphCache.scale) > 0.001) {
        attyx_request_scale_rebuild();
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

- (void)printStatsIfNeeded {
    if (!_debugStats) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _statsLastPrint >= 2.0) {
        double elapsed = now - _statsLastPrint;
        double fps = _statsFrames / elapsed;
        double skipPct = _statsFrames > 0 ? 100.0 * _statsSkipped / _statsFrames : 0;
        double avgDirty = (_statsFrames - _statsSkipped) > 0
            ? (double)_statsDirtyRows / (_statsFrames - _statsSkipped) : 0;
        ATTYX_LOG_DEBUG("renderer", "fps=%.0f skip=%.0f%% avg_dirty=%.1f rows",
                fps, skipPct, avgDirty);
        _statsFrames = 0;
        _statsSkipped = 0;
        _statsDirtyRows = 0;
        _statsLastPrint = now;
    }
}

@end
