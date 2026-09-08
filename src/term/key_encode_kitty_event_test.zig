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

test "kitty disamb+events: arrow press ignores DECCKM and stays canonical" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .down },
        .{ .kitty_flags = flags, .cursor_keys_app = true },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[B", r);
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

test "kitty disamb+events: F3 press uses CPR-safe canonical form" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const r = encodeKey(.{ .key = .f3 }, .{ .kitty_flags = flags }, &buf);
    try testing.expectEqualStrings("\x1b[13~", r);
}

test "kitty disambiguate: modified F3 press uses CPR-safe tilde form" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .f3, .mods = .{ .shift = true } },
        .{ .kitty_flags = KITTY_DISAMBIGUATE },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[13;2~", r);
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

test "kitty event-types: unmodified legacy-byte presses stay legacy and releases drop" {
    var buf: [128]u8 = undefined;
    const cases = [_]struct { key: ke.KeyCode, press: []const u8 }{
        .{ .key = .enter, .press = "\r" },
        .{ .key = .tab, .press = "\t" },
        .{ .key = .backspace, .press = "\x7f" },
    };
    for (cases) |case| {
        const press = encodeKey(
            .{ .key = case.key },
            .{ .kitty_flags = KITTY_EVENT_TYPES },
            &buf,
        );
        try testing.expectEqualStrings(case.press, press);
        const release = encodeKey(
            .{ .key = case.key, .event_type = .release },
            .{ .kitty_flags = KITTY_EVENT_TYPES },
            &buf,
        );
        try testing.expectEqual(@as(usize, 0), release.len);
    }
}

test "kitty event-types: modified legacy-byte releases use CSI u" {
    var buf: [128]u8 = undefined;
    const cases = [_]struct { key: ke.KeyCode, release: []const u8 }{
        .{ .key = .enter, .release = "\x1b[13;5:3u" },
        .{ .key = .tab, .release = "\x1b[9;5:3u" },
        .{ .key = .backspace, .release = "\x1b[127;5:3u" },
    };
    const flag_sets = [_]u5{
        KITTY_EVENT_TYPES,
        KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES,
    };
    for (flag_sets) |flags| {
        for (cases) |case| {
            const release = encodeKey(
                .{
                    .key = case.key,
                    .mods = .{ .ctrl = true },
                    .event_type = .release,
                },
                .{ .kitty_flags = flags },
                &buf,
            );
            try testing.expectEqualStrings(case.release, release);
        }
    }
}

test "kitty disamb+events: text release is suppressed and repeat stays text" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const release = encodeKey(
        .{ .key = .codepoint, .codepoint = 'A', .mods = .{ .shift = true }, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqual(@as(usize, 0), release.len);
    const repeat = encodeKey(
        .{ .key = .codepoint, .codepoint = 'A', .mods = .{ .shift = true }, .event_type = .repeat },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("A", repeat);
}

test "kitty disamb+events: control-key events remain reportable" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const repeat = encodeKey(
        .{ .key = .codepoint, .codepoint = 'a', .mods = .{ .ctrl = true }, .event_type = .repeat },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[97;5:2u", repeat);
    const release = encodeKey(
        .{ .key = .codepoint, .codepoint = 'a', .mods = .{ .ctrl = true }, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[97;5:3u", release);
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

test "kitty all_keys+events: arrow release keeps canonical functional form" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_ALL_KEYS | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .down, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[1;1:3B", r);
}

test "kitty all_keys+events: modifier release is emitted" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_ALL_KEYS | KITTY_EVENT_TYPES;
    const r = encodeKey(
        .{ .key = .right_alt, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[57449;1:3u", r);
}

test "kitty events-only: tilde-key release uses legacy form, not CSI u" {
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .page_up, .event_type = .release },
        .{ .kitty_flags = KITTY_EVENT_TYPES },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[5;1:3~", r);
}

test "kitty disamb+events: F2/F4 release stay letter form (F3 tilde guard does not leak)" {
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const f4 = encodeKey(
        .{ .key = .f4, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[1;1:3S", f4);
    const f2 = encodeKey(
        .{ .key = .f2, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[1;1:3Q", f2);
}

test "kitty disamb+events: escape and kp_enter releases still emitted via CSI u" {
    // kitty's release exemption covers only the three legacy-byte keys
    // (Enter/Tab/Backspace); Escape and KP_ENTER are functional keys with
    // their own CSI-u encodings and DO get releases.
    var buf: [128]u8 = undefined;
    const flags = KITTY_DISAMBIGUATE | KITTY_EVENT_TYPES;
    const esc = encodeKey(
        .{ .key = .escape, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[27;1:3u", esc);
    const kpe = encodeKey(
        .{ .key = .kp_enter, .event_type = .release },
        .{ .kitty_flags = flags },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[57414;1:3u", kpe);
}

test "kitty alternate/associated-only flags: repeat normalizes to press bytes" {
    // Flags with neither event_types nor all_keys (4 = alternate_keys,
    // 16 = associated_text) must treat repeat as press. The pre-fix code
    // leaked CSI-u press-forms here (e.g. \x1b[57420u for an arrow repeat).
    var buf: [128]u8 = undefined;
    const r = encodeKey(
        .{ .key = .down, .event_type = .repeat },
        .{ .kitty_flags = 4 },
        &buf,
    );
    try testing.expectEqualStrings("\x1b[B", r);
}
