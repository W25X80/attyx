const std = @import("std");
const testing = std.testing;

const bridge_header = @embedFile("bridge.h");
const rebuild_bridge = @embedFile("font_rebuild_req.c");
const macos_platform = @embedFile("platform_macos.m");

const rebuild_users = [_][]const u8{
    bridge_header,
    @embedFile("terminal.zig"),
    @embedFile("windows_stubs.zig"),
    @embedFile("main.zig"),
    @embedFile("ui/dispatch.zig"),
    @embedFile("ui/actions.zig"),
    @embedFile("windows_dispatch.zig"),
    @embedFile("ui/event_loop_windows.zig"),
    @embedFile("linux_input.c"),
    @embedFile("platform_linux.c"),
    @embedFile("platform_windows.c"),
    @embedFile("macos_input.m"),
    @embedFile("macos_renderer.m"),
    macos_platform,
};

test "font rebuild synchronization is owned by the bridge API" {
    for ([_][]const u8{
        "void attyx_request_font_rebuild(void);",
        "void attyx_request_scale_rebuild(void);",
        "int attyx_take_font_rebuild_reason(void);",
    }) |declaration| {
        try testing.expect(std.mem.indexOf(u8, bridge_header, declaration) != null);
    }

    for (rebuild_users) |source| {
        try testing.expect(std.mem.indexOf(u8, source, "g_needs_font_rebuild") == null);
    }

    try testing.expect(std.mem.indexOf(u8, rebuild_bridge, "memory_order_release") != null);
    try testing.expect(std.mem.indexOf(u8, rebuild_bridge, "memory_order_acquire") != null);
}

test "macOS resize consumer returns only a claimed request" {
    try testing.expect(std.mem.indexOf(
        u8,
        macos_platform,
        "if (!attyx_resize_try_claim(&g_resize_req, &word)) return 0;",
    ) != null);
}
