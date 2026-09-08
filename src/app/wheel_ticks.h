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
// Semantics mirrored by src/headless/tests/wheel_ticks.zig — keep in sync
// (mirror is scoped to in-range inputs; the clamp below guarantees that).

#ifndef ATTYX_WHEEL_TICKS_H
#define ATTYX_WHEEL_TICKS_H

#include <stdint.h>

// Max ticks per event: 2 x ATTYX_MAX_ROWS. Real hardware deltas sit two
// orders of magnitude below; a synthetic event with a huge delta must not
// saturate the int cast (C UB) or drive an unbounded emission loop, and
// must not bank future ticks in the accumulator.
#define ATTYX_WHEEL_MAX_TICKS 512.0

static inline int attyx_wheel_ticks(double* accum, double dy, int precise,
                                    double cell_h) {
    // NaN would evade both clamps (all comparisons false), poison the
    // accumulator permanently, and hit float->int UB. Unreachable from real
    // NSEvents; guarded so the clamp's safety claim holds for any input.
    if (dy != dy) return 0;
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

typedef struct {
    double accum;
    double cell_h;
    uint64_t owner;
    uint64_t context;
    int initialized;
} AttyxWheelState;

static inline uint64_t attyx_mouse_mode_snapshot_pack(uint32_t generation,
                                                       int tracking,
                                                       int sgr) {
    return ((uint64_t)generation << 32)
         | ((uint64_t)(uint16_t)tracking)
         | ((uint64_t)(sgr != 0) << 16);
}

static inline uint32_t attyx_mouse_mode_snapshot_generation(uint64_t snapshot) {
    return (uint32_t)(snapshot >> 32);
}

static inline int attyx_mouse_mode_snapshot_tracking(uint64_t snapshot) {
    return (int)(snapshot & UINT16_MAX);
}

static inline int attyx_mouse_mode_snapshot_sgr(uint64_t snapshot) {
    return (int)((snapshot >> 16) & 1u);
}

static inline int attyx_wheel_ticks_routed(AttyxWheelState* state, double dy,
                                           int precise, double cell_h,
                                           uint64_t owner, uint64_t context,
                                           int routed) {
    if (!routed) {
        state->accum = 0.0;
        state->initialized = 0;
        return 0;
    }

    double threshold = cell_h > 0.0 ? cell_h : 16.0;
    if (!state->initialized || state->owner != owner ||
        state->context != context || state->cell_h != threshold) {
        state->accum = 0.0;
        state->cell_h = threshold;
        state->owner = owner;
        state->context = context;
        state->initialized = 1;
    }

    return attyx_wheel_ticks(&state->accum, dy, precise, threshold);
}

#endif // ATTYX_WHEEL_TICKS_H
