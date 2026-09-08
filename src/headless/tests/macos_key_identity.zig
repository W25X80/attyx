const std = @import("std");

const c = @cImport({
    @cInclude("macos_key_identity.h");
});

test "macOS ANSI key identities preserve unshifted and shifted forms" {
    try std.testing.expectEqual(@as(u32, 'a'), c.attyx_macos_standard_codepoint(0x00, 0));
    try std.testing.expectEqual(@as(u32, 'A'), c.attyx_macos_standard_codepoint(0x00, 1));
    try std.testing.expectEqual(@as(u32, '1'), c.attyx_macos_standard_codepoint(0x12, 0));
    try std.testing.expectEqual(@as(u32, '!'), c.attyx_macos_standard_codepoint(0x12, 1));
    try std.testing.expectEqual(@as(u32, '['), c.attyx_macos_standard_codepoint(0x21, 0));
    try std.testing.expectEqual(@as(u32, '{'), c.attyx_macos_standard_codepoint(0x21, 1));
    try std.testing.expectEqual(@as(u32, 0), c.attyx_macos_standard_codepoint(0x7E, 0));
}

test "macOS modifier identities distinguish both sides" {
    try std.testing.expectEqual(@as(u16, c.ATTYX_KEY_LEFT_SHIFT), c.attyx_macos_modifier_key(0x38));
    try std.testing.expectEqual(@as(u16, c.ATTYX_KEY_RIGHT_SHIFT), c.attyx_macos_modifier_key(0x3C));
    try std.testing.expectEqual(@as(u16, c.ATTYX_KEY_LEFT_CONTROL), c.attyx_macos_modifier_key(0x3B));
    try std.testing.expectEqual(@as(u16, c.ATTYX_KEY_RIGHT_CONTROL), c.attyx_macos_modifier_key(0x3E));
    try std.testing.expectEqual(@as(u16, c.ATTYX_KEY_LEFT_ALT), c.attyx_macos_modifier_key(0x3A));
    try std.testing.expectEqual(@as(u16, c.ATTYX_KEY_RIGHT_ALT), c.attyx_macos_modifier_key(0x3D));
    try std.testing.expectEqual(@as(u16, c.ATTYX_KEY_LEFT_SUPER), c.attyx_macos_modifier_key(0x37));
    try std.testing.expectEqual(@as(u16, c.ATTYX_KEY_RIGHT_SUPER), c.attyx_macos_modifier_key(0x36));
}

test "UTF-16 key identities decode supplementary scalars" {
    try std.testing.expectEqual(@as(u32, 'x'), c.attyx_utf16_first_scalar('x', 0, 1));
    try std.testing.expectEqual(@as(u32, 0x1F642), c.attyx_utf16_first_scalar(0xD83D, 0xDE42, 2));
    try std.testing.expectEqual(@as(u32, 0), c.attyx_utf16_first_scalar(0xD83D, 0, 1));
    try std.testing.expectEqual(@as(u32, 0), c.attyx_utf16_first_scalar(0xDC00, 0, 1));
}
