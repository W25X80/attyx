#include <assert.h>
#include <stdatomic.h>
#include <stdint.h>

#include "bridge.h"
#include "resize_req.h"

static void test_font_reason_has_priority(void) {
    while (attyx_take_font_rebuild_reason() != 0) {}

    attyx_request_scale_rebuild();
    assert(attyx_take_font_rebuild_reason() == ATTYX_REBUILD_SCALE);
    assert(attyx_take_font_rebuild_reason() == 0);

    attyx_request_scale_rebuild();
    attyx_request_font_rebuild();
    assert(attyx_take_font_rebuild_reason() == ATTYX_REBUILD_FONT);
    assert(attyx_take_font_rebuild_reason() == 0);

    attyx_request_font_rebuild();
    attyx_request_scale_rebuild();
    assert(attyx_take_font_rebuild_reason() == ATTYX_REBUILD_FONT);
    assert(attyx_take_font_rebuild_reason() == 0);
}

static void test_resize_claim_preserves_replacement(void) {
    const uint64_t first = attyx_resize_pack(7, 40, 120);
    const uint64_t replacement = attyx_resize_pack(8, 50, 160);
    _Atomic uint64_t slot = first;

    uint64_t loaded = atomic_load_explicit(&slot, memory_order_acquire);
    atomic_store_explicit(&slot, replacement, memory_order_release);

    assert(!attyx_resize_try_claim(&slot, &loaded));
    assert(atomic_load_explicit(&slot, memory_order_acquire) == replacement);

    loaded = replacement;
    assert(attyx_resize_try_claim(&slot, &loaded));
    assert(atomic_load_explicit(&slot, memory_order_acquire) == 0);
}

int main(void) {
    test_font_reason_has_priority();
    test_resize_claim_preserves_replacement();
    return 0;
}
