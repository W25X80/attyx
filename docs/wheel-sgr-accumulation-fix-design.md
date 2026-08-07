# Wheel Scroll: SGR Tick Accumulation Fix — Design Document

**Status:** Draft for review
**Scope:** `src/app/macos_input.m` (`scrollWheel:`), `src/app/macos_input_private.h`
(two new ivars), one new pure header `src/app/wheel_ticks.h`, one new headless
test file. No term/, config, ABI, or Linux/Windows changes.
**Branch:** `fix/wheel-scroll-accumulation`, cut from `main`.
Overlap note: `macos_input.m` is also touched by the open
`fix/macos-display-scale` branch — method hunks are distant (the
`viewDidChangeBackingProperties` override near line 337 vs. `scrollWheel:`
near line 1053; include-block insertions one line apart, auto-merged).
`src/headless/tests.zig` WILL textually conflict (both branches insert a
different import after the `resize_rounding` line) — a trivial one-line
union with no semantic interaction; merge order does not matter.
Relation to WIP: the untracked `src/app/ui/wheel_route.zig` +
`docs/wheel-routing-sota-blueprint.md` design wheel *routing* (which
destination) and take `lines: i32` as input; the blueprint explicitly
assigns "platform-specific delta normalization" to the platform layer
(blueprint lines 221, 227) and lists "tune precise-delta accumulation" as
future work (line 326). This fix implements exactly that upstream piece and
does not touch routing.

---

## 1. Problem

Mouse-wheel/trackpad scrolling inside TUI apps that enable mouse tracking
(htop, lazygit, `vim` with `mouse=a`, …) is far too fast — a light trackpad
flick scrolls the app by dozens of lines. System-wide scrolling and attyx's
own scrollback are normal.

### 1.1 Root cause (verified in source)

`scrollWheel:` (`src/app/macos_input.m:1053-1112`) has three paths:

- **SGR mouse path** (app enabled mouse tracking, `:1069-1078`) and the
  **popup path** (`:1054-1067`): emit **exactly one SGR wheel tick
  (button 64/65) per NSEvent**, regardless of the event's delta magnitude:

  ```objc
  CGFloat dy = event.scrollingDeltaY;
  if (event.hasPreciseScrollingDeltas) dy /= 3.0;
  if (dy == 0) return;
  ...
  sendSgrMouse(btn, col, row, YES);   // one tick per event
  ```

  Two defects, both provable statically:
  1. `dy /= 3.0` is **dead code**: the only subsequent use of `dy` is the
     exact comparison `dy == 0` (and the sign test). Dividing a nonzero
     float by 3 never yields zero, so the branch never changes — the
     intended 3× attenuation does nothing.
  2. **No accumulation.** A trackpad gesture with
     `hasPreciseScrollingDeltas` delivers dozens of small pixel-delta
     events plus momentum events for ~a second after release (no
     `momentumPhase` filtering exists — grep is empty). Each micro-event
     emits a full wheel tick; the TUI multiplies by its lines-per-tick
     (commonly 3). A flick ⇒ 30–100+ ticks ⇒ 90–300 lines. Text flies.

  Secondary defect (opposite sign): for discrete wheels
  (`hasPreciseScrollingDeltas == NO`), macOS acceleration can deliver
  `|deltaY|` of 5–10 lines in one event — still collapsed to **one** tick,
  so physical mice *under*-scroll in TUIs.

- **Alt-screen arrow path** (`:1093-1101`) and **viewport/scrollback path**
  (`:1103-1111`) consume `lines` computed by a correct pixel accumulator
  (`_scrollAccum` with a cell-height threshold, `:1080-1091`) — these paths
  feel native.

The internal asymmetry (accumulated paths correct, per-event path wrong,
same binary) is what rules out system settings as the cause. Reference
terminals emit SGR wheel ticks from accumulated deltas: kitty at exactly
one tick per cell height (`mouse.c` `scale_scroll`, with multipliers
neutralized to sign in tracking mode), Ghostty the same mechanism with a
deliberate 2× speed multiplier on precise deltas. This fix adopts kitty's
exact rate. Known reference deviations kept deliberately (matching old
attyx semantics): kitty *rounds* discrete deltas (3.7 → 4) where we
truncate (3.7 → 3), and kitty resets the precise accumulator on discrete
events where we preserve it — both sub-tick differences.

---

## 2. Design goals

- **G1 — One tick per line of physical scroll**, in every wheel path:
  precise deltas accumulate against the cell height in points
  (`g_cell_pt_h`, same threshold the correct paths already use); discrete
  deltas emit `trunc(deltaY)` ticks with a minimum of one.
- **G2 — Byte/shape freeze elsewhere:** the alt-screen and viewport paths
  keep their existing accumulator and behavior unchanged; the SGR encoding
  itself (button codes, coordinates, modifiers) is unchanged — only *how
  many* ticks are emitted changes.
- **G3 — Pure, headless-testable core** (project testing mandate): the
  delta→ticks computation is a `static inline` C function in a new header,
  mirrored by Zig tests — the on-`main` precedent is the
  `resize_rounding.zig` mirror pattern (and `resize_req.h` on the open
  display-scale branch establishes the shared-header variant). The mirror
  is scoped to in-range inputs; the helper's clamp keeps both sides inside
  that range by construction.
- **G4 — Momentum needs no rate special-casing:** with accumulation,
  momentum events contribute ticks proportional to glide distance — how
  the already-correct scrollback path behaves, how native apps feel, and
  how Ghostty ships (its core ignores `momentumPhase` entirely). Known
  refinement kitty has that this fix defers (§4 residual iv): kitty pins a
  momentum stream to the window/screen-buffer where the gesture began and
  drops it on change, so quitting a TUI mid-glide doesn't scroll the
  shell underneath. Follow-up, not in scope.

Non-goals: wheel *routing* changes (owned by the WIP blueprint); Linux/
Windows normalization (their input models differ — GLFW/Win32 deliver
line-based deltas; the blueprint assigns per-platform normalization
anyway); DECSET 1007 (alternate-scroll gating) — the alt-screen arrow
fallback is currently unconditional on `g_alt_screen`; pre-existing,
noted for the routing work.

---

## 3. Solution

### 3.1 Pure helper — `src/app/wheel_ticks.h`

```c
// Convert a wheel delta into whole scroll ticks, carrying fractional
// remainder in *accum (precise deltas only).
//  - precise (trackpad, pixel deltas): accumulate; one tick per cell_h
//    points of travel; remainder persists across events (incl. momentum).
//  - discrete (wheel, line deltas): trunc(dy) ticks, at least one in the
//    direction of dy; dy == 0 emits nothing.
//  - both branches clamp to ±512 ticks per event (2 × ATTYX_MAX_ROWS):
//    real hardware deltas are two orders of magnitude below; a synthetic
//    NSEvent with a huge delta must not saturate the int cast (C UB) or
//    drive an unbounded emission loop. The clamp also bounds the pending
//    accumulator, so an adversarial event cannot bank future ticks.
// Returns signed tick count (positive = scroll up).
static inline int attyx_wheel_ticks(double* accum, double dy, int precise, double cell_h)
```

(`double`, not `float`: `CGFloat` is `double` on 64-bit macOS — the only
buildable target — so the extraction stays bit-identical to the original
inline arithmetic.)

Semantics are copied verbatim from the already-correct inline block at
`macos_input.m:1080-1091` (including the `cell_h > 0 ? cell_h : 16.0`
fallback), with **three deliberate deviations**, each pinned by test:
(1) discrete `dy == 0` returns 0 ticks; (2) the ±512/event clamp (absent
from the original block — verified by a 23.5M-event mechanical sweep to be
a no-op for all in-range inputs); (3) a NaN guard (NaN would evade the
clamps, poison the accumulator permanently, and hit float→int UB —
unreachable from real NSEvents, guarded so the clamp's safety claim holds
unconditionally). The pre-fix min-one branch `(dy > 0) ? 1 : -1` maps `dy == 0` to
**−1** — a pure horizontal tilt-wheel event (deltaY exactly 0,
non-precise) reaching the viewport path scrolls one phantom line down.
Pre-existing side bug, fixed by the guard, pinned by test. All other
inputs are behavior-identical.

### 3.2 `scrollWheel:` restructured — all three paths share the helper

- Three independent accumulators (ivars in `macos_input_private.h`):
  `_scrollAccum` (existing, viewport/alt paths), `_sgrScrollAccum` (SGR
  path), `_popupScrollAccum` (popup path). Independent accumulators keep
  mode switches (app toggles mouse tracking mid-gesture) from leaking
  fractional remainders across semantically different consumers; the
  residual error is bounded by <1 cell per switch.
- SGR path: `ticks = attyx_wheel_ticks(&_sgrScrollAccum, dy, precise, cell_h)`;
  emit `|ticks|` SGR wheel events (button by tick sign, same position and
  modifiers for the batch — positions within one event are identical
  anyway). Zero ticks ⇒ no emission (fractional remainder pending).
- Popup path: same with `_popupScrollAccum`, gated by `popupHitTest` as
  today.
- Viewport/alt path: replace the inline block with the helper call
  (behavior-identical by construction).
- The dead `dy /= 3.0` lines are removed — accumulation supersedes the
  intended attenuation.

### 3.3 Behavioral deltas — exhaustive

| Input | Before | After |
|---|---|---|
| Trackpad gesture, SGR path | 1 tick per micro-event (30–100+/flick) | 1 tick per `cell_h` points of travel |
| Momentum tail, SGR path | 1 tick per momentum event | proportional ticks from the same accumulator |
| Discrete wheel notch, SGR path | 1 tick | `trunc(dy)` ticks, min 1 (matches system acceleration) |
| Popup SGR path | same per-event bug | same fix, own accumulator |
| Alt-screen arrows, viewport scrollback | correct accumulation | identical (helper extracted verbatim) |
| Discrete `dy == 0` event (pure horizontal tilt) reaching viewport/alt path | phantom −1 tick | 0 ticks (side bugfix, §3.1) |
| SGR byte format, coordinates, modifiers | — | unchanged |

---

## 4. Correctness argument

**Claim 1 (parity with the correct paths).** The helper is the verbatim
extraction of the accumulator at `macos_input.m:1080-1091` (pre-fix
numbering); the viewport and alt-screen paths produce byte-identical
arrow/scroll behavior for every in-range input with `dy ≠ 0` —
mechanically proven in review cycle 2: 23.5M-event old-vs-new sweep,
bitwise accumulator comparison, 0 mismatches. The only divergences are
the three §3.1 deviations (dy==0 phantom tick, out-of-range clamp, NaN
guard), each deliberate and pinned by test. ∎

**Claim 2 (SGR tick rate).** For a precise-delta stream with total travel
`D` points, the emitted tick count over the stream is
`trunc((D + accum₀) / cell_h)` — one tick per cell of travel independent of
how macOS fragments the stream into events (accumulation is associative
over concatenation of deltas; remainder carries). A TUI at k lines/tick
scrolls k lines per cell of physical travel — the kitty/iTerm2 rate. ∎

**Claim 3 (no phantom or lost ticks).** Ticks are emitted only from whole
multiples of `cell_h` (precise) or nonzero `dy` (discrete); remainders are
carried, never dropped or double-counted, and direction reversal consumes
the remainder before emitting opposite ticks (signed arithmetic). ∎

Residual notes, stated honestly: (i) the fractional remainder persists
between gestures — a stationary sub-cell residue may make the first tick
of the next gesture arrive marginally earlier; kitty behaves the same;
(ii) mode switches (tracking toggled) leave a bounded <1-cell residue in
the inactive accumulator — provably sign-safe (|accum| < threshold after
every event, so a stale residue can never emit a wrong-direction tick);
(iii) all-paths batch emission reuses one event's cell position —
identical to the pre-fix behavior for those paths; (iv) momentum tails are
not pinned to the originating pane/screen-buffer (kitty pins and drops on
change) — quitting a TUI mid-glide lets the ~1s tail scroll what's
underneath; follow-up; (v) the future wheel-routing work (blueprint)
models normalize-once → route with a single accumulator — reconciling
that with this fix's per-path accumulators (and adding the blueprint's
`alt_scroll_speed` multiplier around the helper) is decided there.

---

## 5. Alternatives considered

| Alternative | Why rejected |
|---|---|
| Filter momentum events (`momentumPhase != none` → drop) | Kills native glide feel that the correct paths already provide; treats a symptom — the per-event tick emission stays wrong for the non-momentum stream. |
| Fix the `/= 3.0` into a real threshold (emit tick when `|dy| ≥ 3px`) | Still per-event: a 30px flick event and a 3px event both emit one tick; rate depends on event fragmentation, not travel. Not how any reference terminal behaves. |
| Rate-limit ticks by time | Nondeterministic, feel depends on event timing; breaks slow deliberate scrolls. |
| Do routing + normalization together with the WIP blueprint | The blueprint explicitly splits normalization (platform) from routing (core) and defers accumulation tuning; coupling this fix to uncommitted WIP blocks a shipped bug on unshipped work. |

## 6. Test plan

New headless file `src/headless/tests/wheel_ticks.zig` (registered in
`src/headless/tests.zig`), mirroring `wheel_ticks.h` (the
`resize_rounding.zig` keep-in-sync pattern):

1. Precise stream: 10 events × 3px, cell 17 → ticks only when the
   accumulator crosses 17 (total = trunc(30/17) = 1), remainder 13 carried.
2. Momentum continuation: further 3px events keep producing ticks at the
   same rate (no per-event multiplication) — a 100-event × 3px stream
   yields trunc(300/17) = 17 ticks, not 100.
3. Discrete: dy=1 → 1; dy=3.7 → 3; dy=-5.2 → -5; dy=0.4 → 1 (min-one in
   direction); dy=-0.4 → -1.
4. Direction reversal: +10, +4 (cell 17, no tick, rem 14), then -20
   (rem -6, no tick), then -12 ⇒ -1 tick — remainder is consumed before
   opposite ticks; no phantom double ticks.
5. Zero-height fallback: cell_h = 0 → threshold 16 (parity with
   `macos_input.m:1084`).
6. Verbatim-parity sweep: for a fixed deterministic delta sweep, the
   helper's (ticks, accum) sequence equals the reference inline algorithm
   transcribed from `macos_input.m:1080-1091` (in-range inputs; the
   phantom dy==0 case excluded by construction).
7. Clamp: a synthetic huge precise delta yields exactly ±512 ticks with a
   sub-threshold remainder (no int-cast saturation, no banked ticks);
   discrete ±1e9 yields ±512.
