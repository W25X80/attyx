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
