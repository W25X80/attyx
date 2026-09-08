# Kitty Keyboard Protocol: Release/Repeat Encoding Fix — Design Document

**Status:** Reviewed (two 3-agent adversarial cycles applied; byte-freeze
mechanically proven over the full 399,360-tuple encoder matrix)
**Scope:** `src/term/key_encode.zig` + new `src/term/key_encode_kitty_event_test.zig`
only (pure term layer, headless-tested). No platform, config, or ABI changes.
**Branch:** `fix/kitty-release-encoding`, cut from `main` — this fix shares
zero files with the open `fix/macos-display-scale` branch (verified:
`git diff main fix/macos-display-scale --stat` touches no `src/term/` file),
so it merges independently.

---

## 1. Problem

In TUI applications that enable the kitty keyboard protocol with the
*report event types* flag — notably crossterm/ratatui apps that push
`DISAMBIGUATE_ESCAPE_CODES | REPORT_EVENT_TYPES` (flags = 3) — pressing an
arrow key moves the selection by **two** items: the cursor skips every other
entry. Applications without kitty flags, or with only *disambiguate*
(flags = 1), or with *report all keys* (flag 8), behave correctly.

### 1.1 Root cause (verified in source)

A physical keystroke produces two events: press and release.

- Press: `keyDown` → `attyx_handle_key(KC_DOWN, 0, 1, 0)`
  (`src/app/macos_input_keyboard.m:326`) → `encodeKey` → `encodeKitty`
  (`src/term/key_encode.zig:379`) → *disambiguate* branch routes arrows to
  the legacy encoder `encodeArrow` (`key_encode.zig:396-398`) → `\x1b[B`.
  Correct.
- Release: `keyUp` sends it only when the *event types* bit is active
  (`macos_input_keyboard.m:127-129` — correct gating) →
  `encodeKitty`: the "drop release" filter applies **only when the event
  types flag is clear** (`key_encode.zig:383-385`), so the release proceeds —
  into the same *disambiguate* branch, to the same `encodeArrow`
  (`key_encode.zig:180-207`), **which has no event-type parameter at all**
  → `\x1b[B` again, byte-identical to the press.

The application receives two indistinguishable "Down" sequences per
keystroke. Per the kitty protocol specification, the release must be encoded
with the event-type sub-parameter — `\x1b[1;1:3B` — which protocol-aware
parsers (crossterm, notcurses, kitty's own) decode as a release event and
applications ignore. **Because the emitted press and release bytes are
identical, no application — however correctly written — can filter the
release.** The defect is unambiguously in the terminal.

The same defect covers every functional key routed through the legacy
encoders in the *disambiguate* branch: Home/End (`key_encode.zig:399`),
F1–F4 (`:400`), F5–F12 (`:401`), PgUp/PgDn/Insert/Delete (`:402`). Three
more latent conformance gaps in the same code (all verified against the
kitty spec, kitty's `key_encoding.c`, kitty's test suite, and the crossterm
parser during review cycle 1):

- **Repeat events lose their `:2` sub-parameter** on those keys (encoded as
  plain presses). Benign for movement, but nonconformant: an app that asked
  for event types cannot distinguish repeat from press.
- **Enter/Tab/Backspace releases are emitted** (they route to
  `encodeKittyCSIu`, `key_encode.zig:408-410`, which encodes `:3`). The
  spec forbids this without *report all keys*: "The Enter, Tab and
  Backspace keys will not have release events unless report_all_keys is
  also set, so that the user can still type reset at a shell prompt when a
  program that sets this mode ends without resetting it." Same bug class
  as the arrows (double-Enter in kind-ignoring apps), though filterable
  since these carry `:3`.
- **The `event_types`-without-`disambiguate` branch** (`key_encode.zig:416-419`)
  encodes functional-key release/repeat as CSI u with codepoints kitty
  never emits there; with only *event types* requested, kitty emits the
  legacy-form-with-subparameter encoding (`\x1b[1;1:3B`) — confirmed
  against `key_encoding.c` (`legacy_mode` is false once flag 2 is active).

### 1.2 Affected-population table

| Application class | Kitty flags | Behavior today |
|---|---|---|
| Legacy TUIs (htop, mc, fzf, vim default) | 0 | xterm path drops releases (`key_encode.zig:132`) — OK |
| Disambiguate only | 1 | releases dropped by the filter — OK |
| **crossterm/ratatui default enhancement set** | **3 (1\|2)** | **double-step — this bug** |
| Event types only | 2 | releases sent as nonstandard CSI u; crossterm happens to parse them as filterable releases (mislabeled KEYPAD), other legacy-form parsers glitch |
| + report all keys | 8+ | the `:3`/`:2` sub-params are correct (`key_encode.zig:427-433`), but the CSI-u key numbers themselves are nonconformant — attyx puts F1–F12 on the wire as 57364–57375 (not protocol values; wire PUA starts at F13=57376) and arrows as 57417–57424 (those are the *keypad* arrow keys). Pre-existing, byte-frozen by this fix, out of scope — follow-up issue required |

### 1.3 Why the AppKit layer is not at fault

`keyUp` correctly gates on flag bit 2; arrows return `YES` from
`handleSpecialKey` before `interpretKeyEvents`, so no double delivery exists
at the event layer (`macos_input_keyboard.m:325-327, 370`). The kitty flag
stack itself (per-state, push/pop, `src/term/state.zig:638-663`) is not
implicated: the flags reaching the encoder are the ones the app pushed.

---

## 2. Design goals

- **G1 — Spec conformance:** with the *event types* flag active, every
  non-press functional-key event carries the event-type sub-parameter in
  the legacy-form encoding kitty itself uses: `CSI 1;mods:event {letter}`
  for letter-form keys, `CSI code;mods:event ~` for tilde-form keys.
- **G2 — Press bytes frozen:** the encoding of every *press* event is
  byte-identical before and after this change, in every mode and flag
  combination. Working applications observe zero difference for presses.
- **G3 — Scope containment:** all changes inside `key_encode.zig`'s private
  helpers plus tests. The public API (`encodeKey(KeyEvent, EncoderState,
  *[128]u8)`) and all callers (`src/app/ui/input.zig`, `src/ipc/keys.zig`,
  `src/config/keybinds.zig`, Windows dispatch) are untouched.
- **G4 — Headless-provable:** the encoder is pure; every behavior change is
  pinned by a table-driven unit test (project testing mandate).

Non-goals: implementing `REPORT_ALTERNATE_KEYS` (4) or
`REPORT_ASSOCIATED_TEXT` (16) semantics beyond current behavior; touching
the flag stack, the AppKit layer, or Linux/Windows input paths (they feed
the same pure encoder and inherit the fix automatically).

---

## 3. Solution

### 3.1 Encoding rules (the fix)

One rule, applied uniformly in the kitty paths: **an event is encoded in
"parameterized legacy form" whenever the event-types flag is set and the
event is not a plain press.**

Two spec-mandated exceptions first (both from review cycle 1, verified
against kitty's encoder and test suite):

- **F3 has no parameterized letter form.** `CSI R` collides with the Cursor
  Position Report; the spec removed it ("CSI R conflicts with the Cursor
  Position Report") and kitty encodes any parameterized F3 as
  `CSI 13;mods:event ~`. crossterm's parser dispatches digit-prefixed
  `R`-final sequences to its CPR parser — `\x1b[1;1:3R` would be silently
  dropped. F3 non-press therefore uses the tilde form with code 13.
  (The pre-existing modified-F3 *press* `\x1b[1;{mods}R` has the same
  collision today; it is byte-frozen by G2 and listed as a known deviation
  in §4.1.)
- **Enter/Tab/Backspace get no release events** unless *report all keys*
  is set (spec, quoted in §1.1) — releases of these three keys are
  suppressed, matching kitty's own tests (`release Enter → ''`).

For letter-form keys (arrows `A B C D`, Home `H`, End `F`, F1/F2/F4 `P Q S`):

```
press,   no mods:  ESC [ X        (arrows in DECCKM app mode: ESC O X; F1-F4: ESC O X)   — unchanged
press,   mods:     ESC [ 1;{mods} X                                                       — unchanged
repeat/release:    ESC [ 1;{mods}:{event} X      (mods field present even when 1)         — NEW
```

For tilde-form keys (PgUp 5, PgDn 6, Insert 2, Delete 3, F5–F12 15–24):

```
press,   no mods:  ESC [ {code} ~                — unchanged
press,   mods:     ESC [ {code};{mods} ~         — unchanged
repeat/release:    ESC [ {code};{mods}:{event} ~ — NEW
```

CSI-u keys (codepoints, Escape, numpad — and Enter/Tab/Backspace for
repeat) keep `encodeKittyCSIu`, whose `:{event}` sub-parameter emission is
correct for codepoint keys (verified against kitty: `release 'a'` →
`\x1b[97;1:3u`). Named non-goal: numpad releases in the events-only branch
remain CSI-u (kitty emits nothing for text-producing keys there) —
pre-existing, byte-frozen, follow-up with the flag-8 key-number issue.

Event-type values: `2` = repeat, `3` = release (`1` = press is never
emitted explicitly; kitty omits the default).

### 3.2 Where the rule is applied

1. **`encodeKitty`, disambiguate branch** (`key_encode.zig:393-412`): the
   five legacy-encoder calls gain the event argument. This fixes the
   headline bug.
2. **`encodeKitty`, event-types-only branch** (`key_encode.zig:414-419`):
   functional keys with non-press events switch from CSI u to the same
   parameterized legacy form (conformance gap #3 of §1.1). Codepoint keys
   keep CSI u (correct per kitty's own tests).
2b. **Enter/Tab/Backspace release suppression** (conformance gap #2 of
   §1.1): releases of these three keys return empty unless *report all
   keys* is set — placed in `encodeKitty` after the all_keys dispatch so
   the all_keys path is untouched.
3. **Repeat normalization made explicit:** when the event-types flag is
   *clear*, repeat events encode as plain presses. `encodeKitty` normalizes
   `repeat → press` up front when `flags & KITTY_EVENT_TYPES == 0`, so the
   helpers never see a non-press event they must not encode. For flags 1
   this reproduces the old implicit behavior; for flag sets containing only
   *alternate keys* (4) / *associated text* (16) it is a deliberate
   behavior change — the old code leaked CSI-u press-forms for repeats
   there (e.g. `\x1b[57420u` for an arrow repeat at flags 4); kitty encodes
   such repeats as plain presses. See §3.4.

### 3.3 Mechanics

The five private helpers (`encodeArrow`, `encodeHomeEnd`, `encodeFKey1to4`,
`encodeFKey5to12`, `encodeTildeKey`) gain an `event: EventType` parameter.
`event != .press` forces the parameterized CSI form, never SS3. (Known
deviation, stated precisely: kitty emits *no* SS3 at all once flag 1 or 2
is active — its two permitted forms are `CSI number;mods u` and
`CSI 1;mods [~ABCDEFHPQS]`. Attyx's *press* bytes keep SS3 under DECCKM and
for F1–F4 because G2 freezes presses; crossterm's `ESC O` branch parses all
of them, so the deviation is harmless in practice and left for a follow-up.)
The xterm path passes `.press` literally at all five call sites: it already
returns empty for releases (`key_encode.zig:131-132`), and repeats in xterm
mode are deliberately encoded as presses — passing `.press` freezes those
bytes (G2). All helpers are file-private (`fn`, not `pub`); the signature
change cannot escape the file.

### 3.4 Behavioral deltas — exhaustive

| Input | Before | After | Class |
|---|---|---|---|
| Functional-key **release**, flags ⊇ {event_types}, ∌ all_keys | byte-identical to press (the bug) / CSI u (branch 2) | `CSI 1;1:3 X` / `CSI code;1:3 ~` (F3: `CSI 13;1:3 ~`) | fix |
| Functional-key **repeat**, flags ⊇ {event_types}, ∌ all_keys | plain press bytes | `CSI 1;1:2 X` / `CSI code;1:2 ~` (F3: `CSI 13;1:2 ~`) | conformance; apps that requested event types receive exactly kitty's encoding (crossterm surfaces `KeyEventKind::Repeat`, exactly as under the kitty terminal) |
| Enter/Tab/Backspace **release**, flags ⊇ {event_types}, ∌ all_keys | `CSI 13;1:3 u` etc. emitted | suppressed (empty) | spec-mandated (quoted in §1.1); matches kitty's tests |
| Any-key **repeat**, flags ∈ {4, 16, 20} (alternate/associated only) | CSI-u press-form leak (`\x1b[57420u`, `\x1b[97u`, …) | plain press bytes | conformance: kitty treats repeat as press without event_types; no real app sets these bits without disambiguate; pinned by test |
| Everything else: all presses; all xterm-mode events; flags 0/1; all_keys paths; CSI-u keys | unchanged | unchanged | frozen (G2), mechanically proven: 0 press diffs over the full 399,360-tuple old-vs-new matrix |

The repeat delta is deliberate, spec-required behavior for apps that opted
into event types; it matches what those apps already experience under
kitty, WezTerm, foot and Ghostty, so it cannot regress them relative to
the wider ecosystem.

---

## 4. Correctness argument

**Claim 1 (bug elimination).** With flags ⊇ {event_types}, the encoding of
any release is now either distinct from every press encoding (carries `:3`:
codepoint keys via `encodeKittyCSIu:427-433`, functional keys via the new
parameterized form) or suppressed entirely (Enter/Tab/Backspace, per spec).
Presses never carry an event sub-parameter. A protocol-aware parser
therefore never counts a release as a press. ∎

**Claim 2 (no press regression).** Press encodings are produced by the same
code paths with `event = .press`, under which every helper reproduces its
pre-change byte sequences exactly (the new branch is entered only for
`event != .press`). Pinned by the full pre-existing corpus in
`key_encode_test.zig` (61 tests) which must pass unmodified. ∎

**Claim 3 (release safety in legacy modes).** Releases reach an encoder
only when flag bit 2 is set: the xterm path returns empty
(`key_encode.zig:131-132`), the kitty path filters them when bit 2 is clear
(`:383-385`), and the AppKit layer does not send them at all in that case
(`macos_input_keyboard.m:127-129` — belt and suspenders). Legacy
applications can never observe a release sequence. ∎

**Claim 4 (repeat safety without event types).** With the event-types flag
clear, no `:2` can ever be emitted (normalization precedes all encoding).
For flags 0/1 the emitted bytes reproduce the old behavior exactly; for
flags {4, 16, 20} they deliberately replace the old CSI-u press-form leak
with plain press bytes (§3.4 row 4) — mechanically verified: the full
old-vs-new matrix shows exactly three diff classes (parameterized
non-press, spec-mandated suppression, and this normalization), residue
zero. ∎

*(Line references in Claims 1–3 use pre-fix numbering of
`key_encode.zig`; functions are named so post-fix locations are
unambiguous.)*

Residual risk, stated honestly: applications that enabled event types but
parse only the *plain* legacy forms (accept `\x1b[B` but choke on
`\x1b[1;1:3B`) would mis-parse releases. Such an application is asking for
event types while being unable to parse the encoding the spec mandates for
them — it is broken under kitty/WezTerm/foot/Ghostty today; attyx matching
the ecosystem cannot make it worse. (All encoding forms in §3.1 were
verified in review cycle 1 against the kitty spec, kitty's
`key_encoding.c`, kitty's test suite, and crossterm's parser.)

### 4.1 Known limitations (pre-existing, deliberately out of scope, follow-ups)

- **Popup keyUp gating uses the main pane's flags.** `g_kitty_kbd_flags` is
  published only from the active main pane (`src/app/ui/publish.zig:463`);
  `keyUp` gates on it (`macos_input_keyboard.m:129`) even when routing to
  the popup pane. A flags-3 TUI inside a popup above a flags-0 shell never
  receives releases. Not a regression (delivery was equally suppressed
  before); Claim 1 holds for delivered events.
- **Orphaned releases after consumed presses.** A key whose *press* was
  eaten by a keybind/picker/overlay still gets its *release* forwarded.
  Before this fix that release looked like a phantom press (actively
  harmful); after, it is a `:3` release that protocol-aware apps ignore —
  strictly better, not fully resolved. Full fix (suppress releases of
  consumed presses) is a separate change.
- **Flag-8 CSI-u key numbers are nonconformant** (§1.2 table, last row) —
  byte-frozen here; separate fix.
- **SS3 presses under active kitty flags** (DECCKM arrows, F1–F4, modified
  F3 press `CSI 1;mods R`) deviate from kitty's two-forms rule; harmless
  for crossterm's parser; frozen by G2; separate fix.
- **Enter/Tab/Backspace *presses* under disambiguate are CSI-u**
  (`\x1b[13u` etc.) where the spec mandates legacy bytes ("still generate
  the same bytes as in legacy mode"). Pre-existing, frozen by G2,
  crossterm-compatible; separate fix.
- **KP_ENTER is deliberately NOT in the release-suppression set** — the
  spec's exemption covers only the three legacy-byte keys; KP_ENTER is a
  functional key with its own CSI-u encoding and does get releases
  (matches kitty; pinned by test). A future "consistency" change must not
  add it to the suppression list.

---

## 5. Alternatives considered

| Alternative | Why rejected |
|---|---|
| Drop releases for functional keys even when event types is requested (suppress in `keyUp` or the encoder) | Silently violates the contract the app negotiated; breaks legitimate release-driven UIs (games, chords); papers over the encoder gap instead of fixing it. |
| Encode functional-key releases as CSI u (extend branch-2 behavior to the disambiguate branch) | Wrong direction: uses CSI-u functional codepoints the app only opts into with *disambiguate*/*all keys*; kitty emits the legacy-parameterized form here, and matching the reference implementation is the compatibility-maximizing choice. |
| Route all non-press events through `encodeKittyCSIu` unconditionally | Same objection for branch 1; also changes repeat bytes for CSI-u keys (already correct today) — needless churn. |

---

## 6. Test plan

All new tests live in `src/term/key_encode_kitty_event_test.zig`
(registered via `key_encode.zig`'s trailing `test {}` block; runs headless
in `mod_tests` — project rule satisfied). The existing
`key_encode_test.zig` is untouched at 606 lines (the ~600-line limit
forbids growing it). Test index (24 tests):

1. Arrow release, flags 3 → `\x1b[1;1:3B`; repeat → `\x1b[1;1:2B`;
   release with DECCKM on → `\x1b[1;1:3B` and repeat with DECCKM on →
   `\x1b[1;1:2B` (CSI form, never SS3).
2. Arrow press, flags 3 → `\x1b[B` (frozen); with DECCKM app mode →
   `\x1bOB` (frozen); shift+release → `\x1b[1;2:3B`.
3. Home release flags 3 → `\x1b[1;1:3H`; End repeat → `\x1b[1;1:2F`;
   F1 release → `\x1b[1;1:3P`; F2/F4 release → `\x1b[1;1:3Q`/`S` (the F3
   guard must not leak); **F3 release → `\x1b[13;1:3~` and repeat →
   `\x1b[13;1:2~`** (tilde form, CPR-safe); F3 press frozen (`\x1bOR`);
   F5 release → `\x1b[15;1:3~`; PgUp release → `\x1b[5;1:3~`;
   Delete release → `\x1b[3;1:3~`.
4. Branch 2 (flags = 2 only): arrow release → `\x1b[1;1:3B` (was CSI u);
   tilde-key release → `\x1b[5;1:3~`; arrow press stays xterm `\x1b[B`
   (frozen).
5. Flags 1 only: arrow release → empty and arrow repeat → plain press
   (frozen). Flags 0 release → empty is pinned by the existing corpus
   ("xterm: release event produces nothing").
6. Enter/Tab/Backspace release, flags 3 → empty (suppressed); Enter
   release, flags 8|2 → still emitted via CSI u (all_keys path frozen);
   Escape and KP_ENTER releases, flags 3 → still emitted via CSI u
   (suppression-set boundary).
7. all_keys+events (8|2): arrow release → `\x1b[57420;1:3u` (frozen —
   CSI-u path untouched; key-number nonconformance is §4.1's follow-up).
8. Flags 4 (alternate keys only): arrow repeat → `\x1b[B` (normalization
   pin for §3.4 row 4).
9. The full existing 61-test corpus in `key_encode_test.zig` passes
   unmodified (Claim 2's pin).
