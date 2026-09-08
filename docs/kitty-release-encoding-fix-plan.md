# Kitty Release/Repeat Encoding Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Encode kitty-protocol release/repeat events of functional keys with the `:{event}` sub-parameter instead of bytes identical to a press (design: `docs/kitty-release-encoding-fix-design.md`).

**Architecture:** Thread an `event: EventType` parameter through the five private legacy-form encoders in `key_encode.zig`; non-press events force the parameterized CSI form. Kitty dispatcher normalizes repeat→press when event types is not requested. TDD: tests first.

**Tech stack:** Zig 0.15.2 (`mise x zig@0.15.2 -- zig build test`), pure term layer.

## Global constraints

- Branch: `fix/kitty-release-encoding`, cut from `main` (zero file overlap with `fix/macos-display-scale` — verified).
- Toolchain: system zig is 0.16 and cannot build the project; every gate runs via `mise x zig@0.15.2 -- ...`.
- Known pre-existing failure: `app.daemon.agent_status_test` timeout (flaky, fails on untouched `main`). Gate = no NEW failures.
- Public API `encodeKey` unchanged; only file-private helpers change signature.
- All press byte sequences frozen (design G2): the existing test corpus must pass unmodified.

---

### Task 0: Branch

- [ ] **Step 0.1:** `git checkout -b fix/kitty-release-encoding main`
  (verified safe: no tracked modifications in the working tree; no untracked
  path exists in main's tree; branch name unused).

### Task 1: Failing tests (RED)

**Files:** Create `src/term/key_encode_kitty_event_test.zig` (the existing
`key_encode_test.zig` is already 606 lines; the ~600-line project limit
forbids growing it by another ~200). Modify `src/term/key_encode.zig`
(register the new test file in the `test {}` block at the end, next to the
existing `_ = @import("key_encode_test.zig");`).

- [ ] **Step 1.0:** Register the new file — in `key_encode.zig`'s trailing
  `test {}` block add:

```zig
    _ = @import("key_encode_kitty_event_test.zig");
```

- [ ] **Step 1.1:** Create the new test file with this preamble, then the
  test blocks from Step 1.1a and Step 1.1b:

```zig
//! Tests for kitty-protocol release/repeat encoding of functional keys
//! (docs/kitty-release-encoding-fix-design.md). Split from
//! key_encode_test.zig to respect the ~600-line file limit.
const std = @import("std");
const testing = std.testing;
const ke = @import("key_encode.zig");
const encodeKey = ke.encodeKey;

// Kitty flag constants (mirror key_encode.zig internal constants)
const KITTY_DISAMBIGUATE: u5 = 1;
const KITTY_EVENT_TYPES: u5 = 2;
const KITTY_ALL_KEYS: u5 = 8;
```

- [ ] **Step 1.1a:** The original 14 tests (see the fence below — unchanged
  from the reviewed draft):

```zig
// ---------------------------------------------------------------------------
// Kitty: release/repeat of functional keys (parameterized legacy form)
// ---------------------------------------------------------------------------

test "kitty disamb+events: arrow release uses :3, distinct from press" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .down, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[1;1:3B", r);
}

test "kitty disamb+events: arrow repeat uses :2" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .down, .event_type = .repeat },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[1;1:2B", r);
}

test "kitty disamb+events: arrow press bytes frozen" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(.{ .key = .down }, .{ .kitty_flags = flags }, &buf);
    try testing.expectEqualStrings("\x1b[B", r);
}

test "kitty disamb+events: arrow press in DECCKM app mode frozen (SS3)" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .down },
        .{ .kitty_flags = flags, .cursor_keys_app = true },
        &buf,
    );
    try testing.expectEqualStrings("\x1bOB", r);
}

test "kitty disamb+events: arrow release in DECCKM app mode uses CSI, never SS3" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .down, .event_type = .release },
        .{ .kitty_flags = flags, .cursor_keys_app = true },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[1;1:3B", r);
}

test "kitty disamb+events: shift+arrow release carries mods and :3" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .down, .mods = .{ .shift = true }, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[1;2:3B", r);
}

test "kitty disamb+events: home release and end repeat" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const home = encodeKey(
        .{ .key = .home, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[1;1:3H", home);
    const end = encodeKey(
        .{ .key = .end, .event_type = .repeat },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[1;1:2F", end);
}

test "kitty disamb+events: F1 release uses CSI letter form with :3" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .f1, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[1;1:3P", r);
}

test "kitty disamb+events: tilde-form releases (F5, PgUp, Delete)" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const f5 = encodeKey(
        .{ .key = .f5, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[15;1:3~", f5);
    const pgup = encodeKey(
        .{ .key = .page_up, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[5;1:3~", pgup);
    const del = encodeKey(
        .{ .key = .delete, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[3;1:3~", del);
}

test "kitty events-only: arrow release uses legacy form, not CSI u" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .down, .event_type = .release },
        .{ .kitty_flags = KITTY_EVENT_TYPES },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[1;1:3B", r);
}

test "kitty events-only: arrow press stays plain xterm" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .down },
        .{ .kitty_flags = KITTY_EVENT_TYPES },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[B", r);
}

test "kitty disamb only: arrow release still dropped" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .down, .event_type = .release },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "kitty disamb only: arrow repeat still encodes as plain press" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .down, .event_type = .repeat },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[B", r);
}

test "kitty all_keys+events: arrow release stays CSI u (path frozen)" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_ALL_KEYS | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .down, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[57420;1:3u", r);
}
```

- [ ] **Step 1.1b:** Add the review-cycle additions, inserted at their
  thematic positions in the file rather than appended (F3 tilde form,
  Enter/Tab/Backspace release suppression, DECCKM repeat; cycle 2 added
  five more: events-only tilde release, F2/F4 letter-form boundary,
  escape/kp_enter suppression boundary, flags-4 repeat normalization —
  final content: see `src/term/key_encode_kitty_event_test.zig`, 24 tests):

```zig
test "kitty disamb+events: F3 release uses tilde form (CPR-safe), never CSI R" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .f3, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[13;1:3~", r);
}

test "kitty disamb+events: F3 repeat uses tilde form" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .f3, .event_type = .repeat },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[13;1:2~", r);
}

test "kitty disamb+events: F3 press bytes frozen (SS3)" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(.{ .key = .f3 }, .{ .kitty_flags = flags }, &buf);
    try testing.expectEqualStrings("\x1bOR", r);
}

test "kitty disamb+events: enter/tab/backspace releases are suppressed" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const keys = [_]ke.KeyCode{ .enter, .tab, .backspace };
    for (keys) |k| {
        const r = encodeKey(
            .{ .key = k, .event_type = .release },
            .{ .kitty_flags = flags },
            &buf,
        );
        try testing.expectEqual(@as(usize, 0), r.len);
    }
}

test "kitty all_keys+events: enter release still emitted (all_keys path frozen)" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_ALL_KEYS | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .enter, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[13;1:3u", r);
}

test "kitty disamb+events: arrow repeat with DECCKM on uses CSI form, never SS3" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .down, .event_type = .repeat },
        .{ .kitty_flags = flags, .cursor_keys_app = true },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[1;1:2B", r);
}
```

- [ ] **Step 1.2:** RED gate, precise: run
  `mise x zig@0.15.2 -- zig build test 2>&1 | grep "key_encode_kitty_event"`
  → expect failures ONLY among the new tests; specifically the frozen-press
  and drop-release tests (arrow press, DECCKM press, events-only arrow
  press, F3 press, disamb-only release/repeat, all_keys arrow + enter
  release) are GREEN, everything else in the new file is RED. Baseline
  elsewhere: only the known flaky daemon timeout. (Historical record: the
  actual RED run showed 12 RED / 8 GREEN of the then-20 tests, matching
  this prediction.)

### Task 2: Implementation (GREEN)

**Files:** Modify `src/term/key_encode.zig`.

**Interfaces — produces (file-private):** `encodeArrow(key, mods, app_mode, event, out)`, `encodeHomeEnd(key, mods, event, out)`, `encodeFKey1to4(key, mods, event, out)`, `encodeFKey5to12(key, mods, event, out)`, `encodeTildeKey(key, mods, event, out)` — all with `event: EventType`; `event != .press` forces the `;{mods}:{event}` CSI form.

- [ ] **Step 2.1:** Extend the five legacy encoders. Replace each function with:

```zig
fn encodeArrow(key: KeyCode, mods: Modifiers, app_mode: bool, event: EventType, out: *[128]u8) []const u8 {
    const letter: u8 = switch (key) {
        .up => 'A',
        .down => 'B',
        .right => 'C',
        .left => 'D',
        else => unreachable,
    };

    // Non-press events (kitty event_types flag) carry the event sub-param
    // and always use the CSI numbered form, never SS3.
    if (event != .press) {
        return bufPrint(out, "\x1b[1;{d}:{d}{c}", .{ mods.toCSI(), @intFromEnum(event), letter });
    }

    if (mods.any()) {
        // Modified: ESC[1;{mod}X
        return bufPrint(out, "\x1b[1;{d}{c}", .{ mods.toCSI(), letter });
    }

    if (app_mode) {
        // Application mode: ESC O X
        out[0] = 0x1b;
        out[1] = 'O';
        out[2] = letter;
        return out[0..3];
    }

    // Normal mode: ESC [ X
    out[0] = 0x1b;
    out[1] = '[';
    out[2] = letter;
    return out[0..3];
}

fn encodeHomeEnd(key: KeyCode, mods: Modifiers, event: EventType, out: *[128]u8) []const u8 {
    const letter: u8 = if (key == .home) 'H' else 'F';
    if (event != .press) {
        return bufPrint(out, "\x1b[1;{d}:{d}{c}", .{ mods.toCSI(), @intFromEnum(event), letter });
    }
    if (mods.any()) {
        return bufPrint(out, "\x1b[1;{d}{c}", .{ mods.toCSI(), letter });
    }
    out[0] = 0x1b;
    out[1] = '[';
    out[2] = letter;
    return out[0..3];
}

fn encodeFKey1to4(key: KeyCode, mods: Modifiers, event: EventType, out: *[128]u8) []const u8 {
    // F3's letter form (CSI R) collides with the Cursor Position Report;
    // kitty encodes any parameterized F3 as CSI 13 ~ (the spec removed the
    // CSI R form). crossterm routes digit-prefixed R-final sequences to its
    // CPR parser, which would silently drop CSI 1;1:3 R.
    if (key == .f3 and event != .press) {
        return bufPrint(out, "\x1b[13;{d}:{d}~", .{ mods.toCSI(), @intFromEnum(event) });
    }
    const letter: u8 = switch (key) {
        .f1 => 'P',
        .f2 => 'Q',
        .f3 => 'R',
        .f4 => 'S',
        else => unreachable,
    };
    if (event != .press) {
        return bufPrint(out, "\x1b[1;{d}:{d}{c}", .{ mods.toCSI(), @intFromEnum(event), letter });
    }
    if (mods.any()) {
        return bufPrint(out, "\x1b[1;{d}{c}", .{ mods.toCSI(), letter });
    }
    out[0] = 0x1b;
    out[1] = 'O';
    out[2] = letter;
    return out[0..3];
}

fn encodeFKey5to12(key: KeyCode, mods: Modifiers, event: EventType, out: *[128]u8) []const u8 {
    const code: u8 = switch (key) {
        .f5 => 15,
        .f6 => 17,
        .f7 => 18,
        .f8 => 19,
        .f9 => 20,
        .f10 => 21,
        .f11 => 23,
        .f12 => 24,
        else => unreachable,
    };
    if (event != .press) {
        return bufPrint(out, "\x1b[{d};{d}:{d}~", .{ code, mods.toCSI(), @intFromEnum(event) });
    }
    if (mods.any()) {
        return bufPrint(out, "\x1b[{d};{d}~", .{ code, mods.toCSI() });
    }
    return bufPrint(out, "\x1b[{d}~", .{code});
}

fn encodeTildeKey(key: KeyCode, mods: Modifiers, event: EventType, out: *[128]u8) []const u8 {
    const code: u8 = switch (key) {
        .page_up => 5,
        .page_down => 6,
        .insert => 2,
        .delete => 3,
        else => unreachable,
    };
    if (event != .press) {
        return bufPrint(out, "\x1b[{d};{d}:{d}~", .{ code, mods.toCSI(), @intFromEnum(event) });
    }
    if (mods.any()) {
        return bufPrint(out, "\x1b[{d};{d}~", .{ code, mods.toCSI() });
    }
    return bufPrint(out, "\x1b[{d}~", .{code});
}
```

- [ ] **Step 2.2:** Update the xterm call sites (`encodeXterm`) to pass `.press` literally — xterm already dropped releases at entry, and repeats deliberately keep press bytes:

```zig
        .up, .down, .left, .right => {
            return encodeArrow(event.key, mods, enc_state.cursor_keys_app, .press, out);
        },

        .home, .end => {
            return encodeHomeEnd(event.key, mods, .press, out);
        },

        .f1, .f2, .f3, .f4 => {
            return encodeFKey1to4(event.key, mods, .press, out);
        },

        .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => {
            return encodeFKey5to12(event.key, mods, .press, out);
        },

        .page_up, .page_down, .insert, .delete => {
            return encodeTildeKey(event.key, mods, .press, out);
        },
```

- [ ] **Step 2.3:** Rewrite `encodeKitty` — explicit repeat normalization, event-aware disambiguate branch, and legacy-form functional keys in the events-only branch:

```zig
fn encodeKitty(event: KeyEvent, enc_state: EncoderState, out: *[128]u8) []const u8 {
    const flags = enc_state.kitty_flags;

    // Without the event_types flag: drop release, treat repeat as press.
    var ev = event;
    if (flags & KITTY_EVENT_TYPES == 0) {
        if (ev.event_type == .release) return out[0..0];
        if (ev.event_type == .repeat) ev.event_type = .press;
    }

    // all_keys flag: everything uses CSI u format
    if (flags & KITTY_ALL_KEYS != 0) {
        return encodeKittyCSIu(ev, enc_state, out);
    }

    // Enter/Tab/Backspace never get release events unless all_keys is set —
    // "so that the user can still type reset at a shell prompt when a
    // program that sets this mode ends without resetting it" (kitty spec,
    // Report event types).
    if (ev.event_type == .release) {
        switch (ev.key) {
            .enter, .tab, .backspace => return out[0..0],
            else => {},
        }
    }

    // disambiguate flag: only ambiguous keys use CSI u.
    // Functional keys keep their legacy sequences; non-press events carry
    // the :{event} sub-parameter (parameterized legacy form).
    if (flags & KITTY_DISAMBIGUATE != 0) {
        switch (ev.key) {
            .up, .down, .left, .right => {
                return encodeArrow(ev.key, ev.mods, enc_state.cursor_keys_app, ev.event_type, out);
            },
            .home, .end => return encodeHomeEnd(ev.key, ev.mods, ev.event_type, out),
            .f1, .f2, .f3, .f4 => return encodeFKey1to4(ev.key, ev.mods, ev.event_type, out),
            .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => return encodeFKey5to12(ev.key, ev.mods, ev.event_type, out),
            .page_up, .page_down, .insert, .delete => return encodeTildeKey(ev.key, ev.mods, ev.event_type, out),
            // Numpad keys always use CSI u in Kitty (distinct codepoints)
            .kp_0, .kp_1, .kp_2, .kp_3, .kp_4, .kp_5, .kp_6, .kp_7, .kp_8, .kp_9, .kp_decimal, .kp_divide, .kp_multiply, .kp_minus, .kp_plus, .kp_enter, .kp_equal => {
                return encodeKittyCSIu(ev, enc_state, out);
            },
            // Ambiguous keys use CSI u
            .enter, .tab, .backspace, .escape, .codepoint => {
                return encodeKittyCSIu(ev, enc_state, out);
            },
        }
    }

    // event_types without disambiguate: presses keep plain xterm encoding;
    // non-press functional keys use the parameterized legacy form (what
    // kitty itself emits — CSI-u functional codepoints are reserved for
    // modes the app opted into); non-press CSI-u keys use CSI u.
    if (ev.event_type != .press) {
        switch (ev.key) {
            .up, .down, .left, .right => {
                return encodeArrow(ev.key, ev.mods, enc_state.cursor_keys_app, ev.event_type, out);
            },
            .home, .end => return encodeHomeEnd(ev.key, ev.mods, ev.event_type, out),
            .f1, .f2, .f3, .f4 => return encodeFKey1to4(ev.key, ev.mods, ev.event_type, out),
            .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => return encodeFKey5to12(ev.key, ev.mods, ev.event_type, out),
            .page_up, .page_down, .insert, .delete => return encodeTildeKey(ev.key, ev.mods, ev.event_type, out),
            else => return encodeKittyCSIu(ev, enc_state, out),
        }
    }
    return encodeXterm(ev, enc_state, out);
}
```

- [ ] **Step 2.4:** Run: `mise x zig@0.15.2 -- zig build test` → expect no new failures (all 24 tests in the new file GREEN, all 61 pre-existing tests in `key_encode_test.zig` GREEN unmodified).

### Task 3: Verify + commit

- [ ] **Step 3.1:** Full suite: `mise x zig@0.15.2 -- zig build test` → no new failures. File sizes: `key_encode.zig` ~560 and `key_encode_kitty_event_test.zig` ~310 — both under the limit; `key_encode_test.zig` untouched at 606.
- [ ] **Step 3.2:** Commit:

```bash
git add src/term/key_encode.zig src/term/key_encode_kitty_event_test.zig \
        docs/kitty-release-encoding-fix-design.md docs/kitty-release-encoding-fix-plan.md
git commit -m "fix: kitty protocol encoded key release identically to press

With the kitty keyboard protocol's report-event-types flag active (the
disambiguate|event_types combination crossterm/ratatui apps push),
releasing a functional key emitted bytes identical to its press: the
disambiguate branch routed arrows, Home/End, F-keys and tilde keys to the
legacy encoders, which had no event-type parameter. Apps received two
indistinguishable presses per keystroke - arrow keys moved two items per
press, and no app could filter the duplicate.

- Functional-key release/repeat now encode the parameterized legacy form
  (CSI 1;mods:event X / CSI code;mods:event ~), byte-matching kitty's own
  encoder. F3 uses CSI 13;mods:event ~ (its letter form collides with the
  Cursor Position Report).
- Enter/Tab/Backspace releases are suppressed unless report-all-keys is
  set, as the spec requires.
- The events-only branch (flag 2 without disambiguate) switches functional
  non-press events from CSI-u codepoints to the same legacy form.
- Repeat-as-press normalization without the event-types flag is now
  explicit; all press byte sequences are frozen and pinned by tests.

Design: docs/kitty-release-encoding-fix-design.md"
```

---

## Self-review checklist

- Spec coverage: design §3.1 rules → Task 2.1; §3.2.1 → Task 2.3 disambiguate branch; §3.2.2 → Task 2.3 events-only branch; §3.2.3 → Task 2.3 normalization; §6 test list → Task 1.1 (all 7 groups present). ✓
- No placeholders: every step is literal code or a literal command. ✓
- Type consistency: `event: EventType` parameter name/position identical across all five helpers and all call sites; `ev` (normalized copy) used consistently inside `encodeKitty`. ✓
