#include <stdatomic.h>

#include "bridge.h"

static _Atomic int pending_rebuild_reason = 0;

void attyx_request_font_rebuild(void) {
    atomic_store_explicit(&pending_rebuild_reason, ATTYX_REBUILD_FONT,
                          memory_order_release);
}

void attyx_request_scale_rebuild(void) {
    int expected = 0;
    atomic_compare_exchange_strong_explicit(
        &pending_rebuild_reason, &expected, ATTYX_REBUILD_SCALE,
        memory_order_release, memory_order_relaxed);
}

int attyx_take_font_rebuild_reason(void) {
    return atomic_exchange_explicit(&pending_rebuild_reason, 0,
                                    memory_order_acquire);
}
