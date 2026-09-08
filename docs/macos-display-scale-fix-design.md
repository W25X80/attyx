# macOS Display-Scale Fix — Design Document

**Status:** Reviewed (3-agent adversarial cycle applied)
**Scope:** macOS platform layer (`src/app/platform_macos.m`, `src/app/macos_renderer.m`, `src/app/macos_input.m`, `src/app/macos_internal.h`, one new shared header, one new headless test file), plus a mechanical cross-platform epsilon restoration (§1.1b) that re-applies already-reviewed PR #215 code to the Linux/Windows grid formulas as a separate preparatory commit.

---

## 1. Problem

On multi-display Macs where the displays have different backing scale factors
(e.g. internal Retina panel at 2x + external monitor at 1x), moving the attyx
window from the 1x display to the 2x display corrupts the terminal grid: the
grid is computed at roughly **2× the rows and columns that physically fit**.

User-visible symptoms:

1. The bottom rows of the terminal — including the shell prompt — are rendered
   outside the visible window and cannot be scrolled to (they are part of the
   live screen, not scrollback).
2. Even with the window maximized, text overflows the right edge.
3. Changing the font size shrinks the rendered block but never repairs the
   grid; the terminal remains unusable on the 2x display.

### 1.1 Root cause (verified in source)

The grid is computed by pairing values from **two different moments in time**:

- `mtkView:drawableSizeWillChange:` (`src/app/macos_renderer.m:224-238`)
  divides the **new** drawable pixel size by glyph metrics from the **old**
  glyph cache:

  ```objc
  int new_cols = (int)((size.width - padLpx - padRpx) / _glyphCache.glyph_w + 0.01f);
  ```

  When the window crosses to a display with a different backing scale, AppKit
  delivers the new drawable size (`bounds_pt × S_new`) *before* the deferred
  glyph-cache rebuild runs (`g_needs_font_rebuild` is set in
  `src/app/platform_macos.m:626-635` but only consumed on the next render tick
  in `src/app/macos_renderer.m:184-188`). The stale divisor
  `glyph_w = cell_pt × S_old` yields `new_cols ≈ correct × S_new/S_old` —
  double the columns going 1x→2x.

- The poisoned pair lands in `g_pending_resize_rows/cols`
  (`src/app/macos_renderer.m:235-236`), is drained by the PTY thread via
  `attyx_check_resize` (`src/app/platform_macos.m:211-221`), and
  `handleResize` (`src/app/ui/resize.zig`) then destructively resizes every
  engine, reflows scrollback, and SIGWINCHes the shell.

- **The corruption is persistent in reachable branches, not transient.**
  `rebuildFont` (`src/app/macos_renderer.m:197-222`) installs correct metrics
  but relies on `setContentSize:` to re-trigger the size callback, and that
  callback fires only if the content size in points actually changes. Two
  branches, both broken:
  (a) *Cell point-size coincides across scales* — guaranteed with an integer
  `cell_width` override (`gw = roundf(cell_width × S)` ⇒ `cell_pt ≡
  cell_width`), and possible otherwise — then `setContentSize:` is a no-op,
  the callback never fires, and the poisoned grid is never recomputed.
  (b) *Cell point-size differs per scale* (e.g. Menlo 14pt: 8.0pt at 1x vs
  8.5pt at 2x) — the callback does fire, but if the PTY thread drained the
  poisoned pair first, `g_cols/g_rows` are already ~2×, and `setContentSize:`
  blows the window up to ~2× the screen (the §1.2 wrong fixed point). Which
  branch wins is a race; neither self-corrects to a usable state.

- `rebuildFont`'s unconditional `setContentSize:(g_cols × cell_pt)` also forms
  a feedback edge *grid → window*. With a poisoned grid it resizes the window
  to ~2× the screen, overriding `fitWindowToCurrentScreen`
  (`src/app/platform_macos.m:607-624`), which ran earlier in the same
  transition.

- Independent latent defect: `g_pending_resize_rows` and
  `g_pending_resize_cols` are two separate `volatile int`s
  (`src/app/platform_macos.m:108-109`). The PTY thread can observe a torn
  pair (new rows, old cols) between the two main-thread stores. `volatile`
  provides no atomicity or ordering guarantees under the C11 memory model.

### 1.1b Related latent regression discovered during this analysis

PR #215 ("Scrollback on smaller screens", merged as `43c3067`) tightened the
grid-formula epsilon from `+0.01f` to `+0.001f` across all platforms and
added `src/headless/tests/resize_rounding.zig` documenting the tight value
(the test mirrors the formula in Zig; it does not link the C code, so it
passes against either epsilon). The merged tree (`43c3067`), however,
retained `0.01f` in **every** platform file, while branch commit `4ee6101`
contained the code change — the merged PR head also contains hunks absent
from `4ee6101`, so the epsilon change was evidently lost on the PR branch
itself before the squash-merge, not by the merge. Either way the operative
fact is verified on current `main`: the tests document `0.001` while the
shipped code uses `0.01` — the "phantom bottom row on small screens" bug
that #215 set out to fix is still live. This is a second,
independent contributor to symptom 1 on a 13" internal panel.

This design restores the intended `0.001f` (a re-application of an
already-reviewed fix, gated by tests already on `main`) as a separate
preparatory commit, at all sites: `macos_renderer.m:229-230`,
`platform_macos.m:541-542`, `platform_linux.c:423-424,621-622`,
`linux_input.c:1302-1303`, `platform_windows.c:402-403,569-570`.

### 1.2 Why the current design cannot be patched cosmetically

Model one settle step of the current system as `W′ = h(G)`, `G′ = g(D(W), M)`
where `W` is window size, `D` drawable, `G` grid, `M` glyph metrics, and
`h` = `setContentSize:` fitting the window exactly to the grid. Because `h`
fits the window *exactly*, `h ∘ g` is the identity on **any** grid — the
system has a continuum of fixed points, one per grid value, including the
poisoned ones. Which fixed point the system lands in is decided by a race
(callback order vs. deferred rebuild). No amount of tweaking the arithmetic
changes the fixed-point structure; the *edges* of the dataflow graph must
change.

---

## 2. Design goals

- **G1 — Correct-by-construction:** the grid must never be computed from a
  drawable size and glyph metrics that belong to different scales, regardless
  of AppKit callback ordering.
- **G2 — Self-correcting:** any transient wrong grid must be overwritten by a
  correct one within one render tick, with no dependency on AppKit
  "noticing" a change.
- **G3 — No cross-thread tearing:** the PTY thread must never observe a
  half-updated resize request.
- **G4 — Zero regressions:** on single-display and uniform-scale systems the
  observable behavior must be bit-for-bit identical (same formula, same
  epsilon, same rounding). The Zig layer and the Linux/Windows platform
  layers must not change at all.
- **G5 — Testable headlessly** per the project testing mandate.

Non-goals: replacing MTKView with a hand-rolled CAMetalLayer host (Ghostty's
approach), changing resize UX, touching `term/` or the renderer's drawing
code.

---

## 3. Solution architecture

Four coordinated changes, all confined to the macOS platform layer.

### C1 — Scale-coherence guard (achieves G1)

Single scale source for the entire design: `S_live =
view.window.backingScaleFactor` (fallback `[NSScreen mainScreen]` only when
the window is nil). Unlike `window.screen.backingScaleFactor`, this is
defined even while `window.screen` is transiently nil during transitions,
and it is the scale AppKit actually uses for the window's backing store —
the guard, the rebuild, and the layer sync (C4) all read the same value, so
they can never disagree with each other.

In `mtkView:drawableSizeWillChange:`: if `S_live != _glyphCache.scale`,
**do not publish a grid request**; arm `ATTYX_REBUILD_SCALE` and return.
Otherwise compute cols/rows with the same formula (epsilon `+0.001f` after
the §1.1b restoration).

Staleness is now detected by *direct comparison of the two values being
paired*, not inferred from notification ordering. This is the load-bearing
move: no publication path may pair a size with metrics unless both are
anchored to `S_live` at the same program point (see also C3's republish,
which achieves coherence by construction rather than by checking).

### C2 — Atomic, generation-tagged resize requests (achieves G2, G3)

Replace the two `volatile int`s with a single C11 atomic word plus a metrics
generation counter:

```
g_resize_req    : _Atomic uint64_t   // [gen:32 | rows:16 | cols:16]
g_metrics_gen   : _Atomic uint32_t   // bumped by rebuildFont after installing metrics
```

- Producers (all on the main thread): the launch-time block
  (`platform_macos.m:538-551`), `drawableSizeWillChange`, and `rebuildFont`
  publish `pack(g_metrics_gen, rows, cols)` with a release store.
- Consumer: `attyx_check_resize` keeps its exact signature
  (`int attyx_check_resize(int*, int*)`, `src/app/bridge.h:97`). It performs
  one acquire load (the triple is inherently untearable — one word), rejects
  requests whose `gen != g_metrics_gen` (stale-metrics filter), preserves the
  existing `rows==g_rows && cols==g_cols` no-op suppression, and drains via
  compare-and-swap to zero.

The Zig side is untouched: same C ABI, same semantics ("returns 1 with a
fresh, safe grid, else 0").

### C3 — Rebuild-reason split (achieves G2, breaks the grid→window cycle)

`g_needs_font_rebuild` becomes a reason code. **Existing writers already
write `1`** (`src/app/ui/dispatch.zig:237,245,251`,
`src/app/ui/actions.zig:715`) — define:

```
ATTYX_REBUILD_FONT  = 1   // user changed font/cell config (existing Zig writers, unchanged)
ATTYX_REBUILD_SCALE = 2   // display scale changed (set only inside the macOS layer)
```

In `rebuildFont`:

- `ATTYX_REBUILD_FONT`: current behavior preserved — `setContentSize:` keeps
  the grid constant and lets the window grow/shrink, then the size callback
  recomputes coherently (scale unchanged ⇒ guard passes; new metrics already
  installed). One addition: the target content size is clamped to the
  screen's `visibleFrame`; clamping only engages where the old behavior
  already pushed the window off-screen.
- `ATTYX_REBUILD_SCALE`: **no** `setContentSize:` — the window's point frame
  is preserved (kitty/Ghostty behavior: dragging across displays keeps the
  window's point size).

**Unconditional coherent republish.** Regardless of reason, *every* rebuild
ends by publishing the grid computed from `view.bounds × S_live` with the
just-installed metrics (which were rasterized at the same `S_live`, in the
same program run of `rebuildFont`). Two properties follow:

1. *Coherence by construction:* the pair (size, metrics) is anchored to one
   `S_live` read at one program point. It does not matter whether
   `view.drawableSize` has caught up with the screen change yet — the
   published grid describes the settled state `bounds × S_live`, and when
   the drawable does catch up, the guarded callback republishes the same
   value (no-op suppressed). This is what makes G1 hold *regardless of
   AppKit callback ordering*: no path reads the drawable and the metrics at
   different times. (An earlier draft republished from `view.drawableSize`;
   review found the ordering hole — a rebuild running before the drawable
   update would pair new metrics with the old drawable.)
2. *Liveness without AppKit:* publication no longer depends on
   `setContentSize:` producing a size callback. The clamped-FONT case
   (target size equals current size ⇒ no callback) and the pure-scale case
   (point size unchanged ⇒ no callback) are both covered by the same
   unconditional republish. Every `g_metrics_gen` bump is followed, in
   program order on the same thread, by a publish carrying the new
   generation — the invariant the §4 liveness argument rests on.

Ordering requirement: the `g_metrics_gen` bump happens *before*
`setContentSize:`, so the re-entrant guarded callback (if any) publishes
with the post-bump generation and is not self-rejected.

Reason-flag concurrency: `g_needs_font_rebuild` is a plain exported int
written by the PTY thread (config reload, `src/app/ui/actions.zig:715`,
value 1) and by the main thread. SCALE arming uses a compare-and-swap from 0
(`__atomic_compare_exchange_n`) and consumption uses an atomic exchange, so
a concurrent FONT store always wins over SCALE arming — FONT is the stronger
reason (it also rasterizes at `S_live`, and additionally resizes the
window). The residual mixed-atomic/plain access on this flag matches the
codebase's existing volatile discipline and only narrows a pre-existing race
window; the consequence of losing it is benign (a reflow instead of a window
resize), never an incoherent grid — coherence is carried entirely by C1/C2
and the republish, not by the flag.

### C4 — Explicit layer-scale sync (defense in depth)

Override `viewDidChangeBackingProperties` on `AttyxView`
(`src/app/macos_input.m`): capture the layer's `contentsScale`, call
`super`, set `self.layer.contentsScale = self.window.backingScaleFactor`,
and arm `ATTYX_REBUILD_SCALE` **only if the captured scale differs from the
window's** — the notification also fires on first window attachment at
launch, where scales already match; arming unconditionally would make a
second full glyph-cache rasterization on every launch (review finding).
On healthy AppKit builds the sync duplicates what MTKView does internally;
on Monterey with `presentsWithTransaction = YES` and a custom
`layerContentsPlacement` it removes any reliance on undocumented MTKView
internals. Even if the conditional skips arming while the glyph cache is
stale, the C1 guard catches the mismatch on the next drawable callback —
C4 is belt, not load-bearing.

### C5 — Pure logic extraction + headless tests (achieves G5)

The grid formula and the request word pack/unpack/filter live in a new
header of `static inline` C functions, `src/app/resize_req.h`, included by
both `.m` files. A new headless test
`src/headless/tests/resize_scale_coherence.zig` (registered in
`src/headless/tests.zig`) mirrors the semantics in Zig — the established
pattern of `src/headless/tests/resize_rounding.zig`, which already mirrors
this exact platform formula with a keep-in-sync comment. Tests cover:

- pack/unpack round-trip over the full field ranges (gen 0, 2³²−1; rows/cols
  1, MAX);
- torn-pair impossibility is structural (single word) — test asserts
  round-trip identity, documenting the invariant;
- stale-generation rejection and same-value suppression;
- scale-coherence scenarios: 1x→2x and 2x→1x transitions produce no request
  until metrics match, then produce the correct grid;
- the existing no-overflow invariant (`rows·cell + pad ≤ drawable`) across
  scale transitions.

---

## 4. Formal correctness argument

**Environment inputs** (piecewise constant): `S` = backing scale of the
window's screen, `B` = view bounds in points, `F` = font configuration.
**System state:** metrics `M` with rasterization scale `σ(M)` and cell pixel
size `px(M)`; request word `R = (gen, rows, cols)`; grid `G`; flag `φ`;
generation `γ`. Main thread runs all producers and `rebuildFont`; the PTY
thread is the sole consumer.

**Invariant I1 (publication coherence).** Every write of `R` carries a grid
of the form `clamp(⌊(size_px − pad·s) / px(M)⌋)` where `size_px` and `M` are
anchored to the same scale `s = σ(M)`, and `R.gen = γ` at write time.
*Proof.* Exactly three program points write `R`, all main-thread.
(a) `drawableSizeWillChange` is guarded by `S_live = σ(M)`, else returns
without writing; the size it uses is the drawable AppKit is about to adopt
for that same backing scale. (b) `rebuildFont`'s unconditional republish
does not read the drawable at all: it computes `size_px = bounds × S_live`
from the same `S_live` it just rasterized `M` at, in one program run —
coherent by construction, independent of whether the actual drawable has
caught up (when it does, the guarded callback republishes the identical
value). (c) The launch block computes from metrics it just created at the
live scale. No other writer exists; producers never race each other (same
thread). ∎

**Invariant I1-b (republish follows every bump).** Every increment of `γ`
is followed, in program order on the main thread, by a write of `R` with the
new `γ` (the unconditional republish at the end of `rebuildFont`). No code
path bumps `γ` and returns before publishing. ∎

**Invariant I2 (consumption coherence).** The PTY thread applies only values
obtained from a single atomic load whose `gen` equals `γ`, and rejection
never destroys a live request.
*Proof.* The triple lives in one 64-bit word: one acquire load yields a
mutually consistent triple — torn pairs are structurally impossible.
*Load order matters and is fixed:* the consumer loads `R` first (acquire),
then `γ` (acquire). The publisher bumps `γ` before storing `R` (both on one
thread; the store is release). Hence if the consumer sees a word with
generation `g`, the acquire on that load makes the publisher's prior `γ = g`
visible, so the subsequent `γ` load returns ≥ `g`: a *fresh* word can never
be misjudged stale. Only genuinely stale words (`gen < γ`) are rejected, and
draining them is safe by I1-b — the bump that outdated them has already
been followed by a fresh publish, and the drain is a CAS on the exact loaded
word, so it can never remove a newer word (the CAS simply fails). Release
ordering on the publisher makes the metrics matching `gen` visible to any
consumer that accepts the word. (Gen wraparound needs 2³² rebuilds in one
session — outside the operating envelope.) ∎

**Acyclicity.** Post-fix dataflow edges for scale transitions:
`S → M`, `(B,S) → D`, `(D,M) → R`, `R → G`, `G → PTY`. `B` depends only on
user action and `fitWindowToCurrentScreen` (a function of the screen's
`visibleFrame` alone). C3 deletes the sole back edge `G → B` on the scale
path ⇒ the graph is a DAG ⇒ every event cascade terminates. On the FONT path
the `G → B` edge exists by design, but `S` and `M` are then fixed, and the
recomputed request equals the grid-preserving target, which the
`rows==g_rows && cols==g_cols` check turns into a no-op — the cycle cannot
re-fire itself in execution.

**Theorem (convergence to the unique fixed point).** Model precisely:
*environment inputs* are `S`, `F`, and the user's window operations; the
bounds `B` are *system state* (written by user resizes, by
`fitWindowToCurrentScreen`, and — on the FONT path only — by
`setContentSize:`). Assume the environment quiesces after t₀ (no further
user/AppKit events), the display link keeps firing (non-paused MTKView —
producer fairness), and the PTY loop keeps polling `attyx_check_resize`
(consumer fairness). Then the system reaches
`X* = (B*, M*, G*, φ=0, R drained)` with `M* = createGlyphCache(F, S)` and
`G* = clamp(⌊(B* − pad_pt)/cell_pt(M*)⌋)` within finitely many steps
(≤ 2 rebuilds, ≤ 1 FONT-path window write, then one consumer poll), and
`X*` is the unique fixed point for the given `(S, F, B*)`.
*Proof sketch.* (1) *B stabilizes.* After t₀ only the system writes `B`, and
the only system writer is the FONT branch of `rebuildFont`, which runs once
per consumed flag; consuming the flag does not re-arm it (the guarded
callback triggered by `setContentSize:` publishes but never arms — its arm
condition `S_live ≠ σ(M)` is false, metrics were just installed at
`S_live`). So `B` is written at most once after t₀: `B* ` is reached.
(2) *M stabilizes.* The first tick after the last arming consumes `φ` and
installs `σ := S`; thereafter every arm-site predicate (`σ ≠ S` in the
guard, scale-difference in C4) is false — `φ` stays 0, metrics converge in
≤ 2 rebuilds. (3) *R converges.* Producers fire only on size events (finite:
B stabilized) or inside `rebuildFont` (finite by (2)); by acyclicity `G`
feeds no producer, so applying a resize generates no new request. The final
write of `R` is the last republish and by I1/I1-b equals `(γ*, G*)`.
(4) *G converges.* Last-writer-wins consumption with the I2 filter applies
`G := G*` on the next PTY poll, after which `attyx_check_resize` returns 0
forever. (5) *Uniqueness.* Given `(S, F, B*)`, the fixed-point equations are
a composition of deterministic functions; no race-dependent hidden state
remains (pre-fix, `W` encoded race history — the continuum of wrong fixed
points of §1.2). ∎

**Corollaries — each symptom becomes unreachable.**
With I1+I2, every applied grid satisfies `rows·cell_px + pad ≤ D.h` and
`cols·cell_px + pad ≤ D.w` at matching scale: no off-window bottom rows
(symptom 1), no horizontal overflow at any window size including fullscreen
(symptom 2). Convergence guarantees font-size changes always land on the
unique correct grid (symptom 3). The identity
`(B·S − pad·S)/(cell_pt·S) = (B − pad)/cell_pt` means the converged grid
depends on `S` only through the per-scale pixel snapping of `cell_pt`
(`roundf(advance·S)/S`): with an integer `cell_width` override the grid is
preserved exactly across displays; with fractional natural advances it
shifts by the snapping delta (e.g. Menlo 14pt, 800pt window: 100 cols at 1x
vs 94 at 2x). What is preserved unconditionally is the window's point
frame — the window never resizes on a scale change, and the grid always
fits it.

---

## 5. Why this is the best available solution

Alternatives considered and rejected:

| Alternative | Why rejected |
|---|---|
| **Synchronous glyph-cache rebuild inside `viewDidChangeBackingProperties`** | As a replacement for C1 specifically: it performs Core Text rasterization + Metal texture allocation inside an AppKit layout notification (first-frame jank, reentrancy hazards with `presentsWithTransaction`), and — unlike the guard — still *assumes* the notification precedes the drawable callback. It could be combined with C2/C3, but the guard achieves the same coherence with zero work in the notification and no ordering assumption. |
| **Compute the grid purely in points (`bounds / cell_pt`), ignore pixels** | Elegant, but `cell_pt = round(natural_px)/S` differs per scale (pixel snapping: Menlo 14pt ⇒ 8.0pt at 1x, 8.5pt at 2x), so a points-based grid computed against about-to-be-replaced metrics can transiently overflow, and the approach silently changes rounding behavior on *all* systems — violating G4. The guard keeps the shipped formula on uniform-scale systems. (C3's republish *does* use `bounds × S_live` — but always paired with metrics rasterized at that same `S_live`, which is the actual requirement.) |
| **Trust AppKit notification ordering** (rebuild first, then compute) | The relative ordering of `windowDidChangeScreen` / `windowDidChangeBackingProperties` / drawable callbacks is undocumented; the current bug is what that assumption produces on at least one shipping configuration (this report's reproduction). Any fix that depends on ordering re-introduces the race class. |
| **Replace MTKView with a hand-managed CAMetalLayer** (Ghostty) | The genuinely maximal solution, but a rewrite of the entire view/present layer with its own new failure modes — grossly disproportionate to the defect and impossible to validate as regression-free within this codebase's test surface. |
| **Clamp the grid to "sane" bounds heuristically** | Treats the symptom; a 2×-poisoned grid on a large monitor is within "sane" bounds for a bigger monitor. No invariant, no proof. |

The chosen design is the smallest change that makes the invariants *checkable
at the point of use* (compare the two scales being paired), removes the only
cycle in the dataflow graph, and upgrades the cross-thread handoff to the C11
memory model — while keeping the shipped arithmetic byte-identical where it
was already correct.

### 5.1 Regression argument (exhaustive over touched behaviors)

Baseline for "identical": the tree after the preparatory §1.1b commit — the
epsilon restoration itself intentionally changes edge-case grids on all
platforms (that is re-applied #215 behavior, gated by the on-`main` tests).

| Behavior | Before (post-§1.1b) | After | Proof of preservation |
|---|---|---|---|
| Same-scale window resize | formula in `drawableSizeWillChange` | identical formula | guard passes (`S_live == σ`), code path unchanged |
| Launch sizing | launch block computes in points | same values via `pack` | same arithmetic, same consumer semantics; C4 arms nothing at launch (scales equal), so no extra rebuild |
| Font size change (fits on screen) | `setContentSize:` preserves grid | identical + trailing no-op republish | FONT path keeps `setContentSize:`; clamp inactive when target fits; republish suppressed as no-op |
| Font size change (would exceed screen) | window grows off-screen, grid intact | content size clamps to screen, grid recomputes for the clamped size | unconditional republish guarantees the recompute (no callback dependency); old off-screen-window behavior deliberately replaced — documented UX change, engages only where the window no longer fit the screen. Origin is not moved; only the size is clamped. |
| Fullscreen font change | `setContentSize:` ignored by fullscreen ⇒ grid/window mismatch persisted | republished grid matches the real drawable | unconditional republish from live bounds×scale — strict improvement |
| Config reload (font/cell change) | flag = 1 | flag = 1 = FONT | Zig writers untouched; PTY-thread store wins over SCALE arming (CAS from 0) |
| Scale transition | poisoned grid (the bug) | guarded + republished | this is the fix |
| Zig event loop / PTY / daemon startup wait | `attyx_check_resize` contract; deferred-daemon 2s dims wait (`event_loop.zig:289-311`) | same ABI; gen filter added | fresh words can't be misjudged stale (I2 load-order proof); every bump is followed by a same-thread republish (I1-b) landing well inside one 50ms poll tick; gen-0 launch word stays valid if no rebuild occurs. Timeout reachability unchanged. |
| Old no-op non-clearing quirk | no-op pending pair retained | no-op pair drained | exhaustive consumer audit: `attyx_set_grid_size` called only with dims freshly returned by `attyx_check_resize` — retained pairs were dead state |
| Linux / Windows platform | own globals in own files | untouched beyond §1.1b epsilon | separate translation units (`platform_linux.c`, `platform_windows.c`) |
| Renderer draw path | reads `_glyphCache` on main thread | unchanged | no changes to draw code |

Residual assumptions, stated explicitly: (i) display-link fairness (flag is
consumed) — holds for a non-paused MTKView (`platform_macos.m:499`);
(ii) `createGlyphCache` determinism for fixed `(F, S)`
(`src/app/macos_font.m:85`) — it is a pure function of config globals and
scale; (iii) PTY-loop polling fairness (requests are drained) — holds, the
event loop polls `attyx_check_resize` every iteration
(`src/app/ui/resize.zig:31`) and every ≤50ms during startup waits;
(iv) pre-existing benign races on unrelated globals (e.g. `g_cell_w_pts`
readers) are out of scope and unchanged; (v) transient frames: for at most
one render tick between an arming event and its rebuild, the on-screen frame
may show the old atlas on the new scale (slight blur) — visual only,
self-corrected by the next tick.

---

## 6. Test plan

1. **Headless unit tests** (`zig build test`, no rendering):
   `resize_scale_coherence.zig` as specified in C5.
2. **Compile-level verification:** `exe_tests` on macOS links the full
   platform layer — the new header and atomics compile into both `.m` files.
3. **Manual verification matrix** (documented in the PR): single display 1x;
   single display 2x; drag 1x→2x and 2x→1x; font ± on each; maximize on each;
   fullscreen on each; config-reload font change on 2x.
