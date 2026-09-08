const testing = @import("std").testing;

const gate = @cImport({
    @cInclude("glfw_char_gate.h");
});

test "GLFW character suppression is consumed once" {
    var suppress: c_int = 1;

    try testing.expectEqual(@as(c_int, 1), gate.attyx_glfw_take_suppressed_char(&suppress));
    try testing.expectEqual(@as(c_int, 0), suppress);
    try testing.expectEqual(@as(c_int, 0), gate.attyx_glfw_take_suppressed_char(&suppress));
}

test "GLFW new key discards stale suppression" {
    var suppress: c_int = 1;

    gate.attyx_glfw_begin_key(&suppress);
    try testing.expectEqual(@as(c_int, 0), suppress);
}
