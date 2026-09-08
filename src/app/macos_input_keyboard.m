// Attyx — AttyxView keyboard handling

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#include <limits.h>
#include "macos_internal.h"
#include "macos_key_identity.h"

// KeyCode enum values (must match src/term/key_encode.zig KeyCode)
enum {
    KC_UP = 0, KC_DOWN, KC_LEFT, KC_RIGHT,
    KC_HOME, KC_END, KC_PAGE_UP, KC_PAGE_DOWN,
    KC_INSERT, KC_DELETE,
    KC_BACKSPACE, KC_ENTER, KC_TAB, KC_ESCAPE,
    KC_F1, KC_F2, KC_F3, KC_F4, KC_F5, KC_F6,
    KC_F7, KC_F8, KC_F9, KC_F10, KC_F11, KC_F12,
    KC_KP_0, KC_KP_1, KC_KP_2, KC_KP_3, KC_KP_4,
    KC_KP_5, KC_KP_6, KC_KP_7, KC_KP_8, KC_KP_9,
    KC_KP_DECIMAL, KC_KP_DIVIDE, KC_KP_MULTIPLY,
    KC_KP_MINUS, KC_KP_PLUS, KC_KP_ENTER, KC_KP_EQUAL,
    KC_CODEPOINT,
    KC_LEFT_SHIFT, KC_LEFT_CONTROL, KC_LEFT_ALT, KC_LEFT_SUPER,
    KC_RIGHT_SHIFT, KC_RIGHT_CONTROL, KC_RIGHT_ALT, KC_RIGHT_SUPER,
};

_Static_assert(KC_LEFT_SHIFT == ATTYX_KEY_LEFT_SHIFT, "KeyCode values must match Zig");
_Static_assert(KC_CODEPOINT == ATTYX_KEY_CODEPOINT, "KeyCode values must match Zig");
_Static_assert(KC_RIGHT_SUPER == ATTYX_KEY_RIGHT_SUPER, "KeyCode values must match Zig");

static uint16_t mapKeyCode(unsigned short kc) {
    switch (kc) {
        case kVK_UpArrow:      return KC_UP;
        case kVK_DownArrow:    return KC_DOWN;
        case kVK_RightArrow:   return KC_RIGHT;
        case kVK_LeftArrow:    return KC_LEFT;
        case kVK_Home:         return KC_HOME;
        case kVK_End:          return KC_END;
        case kVK_PageUp:       return KC_PAGE_UP;
        case kVK_PageDown:     return KC_PAGE_DOWN;
        case kVK_Help:         return KC_INSERT;
        case kVK_ForwardDelete:return KC_DELETE;
        case kVK_Delete:       return KC_BACKSPACE;
        case kVK_Return:       return KC_ENTER;
        case kVK_Tab:          return KC_TAB;
        case kVK_Escape:       return KC_ESCAPE;
        case kVK_F1:           return KC_F1;
        case kVK_F2:           return KC_F2;
        case kVK_F3:           return KC_F3;
        case kVK_F4:           return KC_F4;
        case kVK_F5:           return KC_F5;
        case kVK_F6:           return KC_F6;
        case kVK_F7:           return KC_F7;
        case kVK_F8:           return KC_F8;
        case kVK_F9:           return KC_F9;
        case kVK_F10:          return KC_F10;
        case kVK_F11:          return KC_F11;
        case kVK_F12:          return KC_F12;
        case kVK_ANSI_Keypad0: return KC_KP_0;
        case kVK_ANSI_Keypad1: return KC_KP_1;
        case kVK_ANSI_Keypad2: return KC_KP_2;
        case kVK_ANSI_Keypad3: return KC_KP_3;
        case kVK_ANSI_Keypad4: return KC_KP_4;
        case kVK_ANSI_Keypad5: return KC_KP_5;
        case kVK_ANSI_Keypad6: return KC_KP_6;
        case kVK_ANSI_Keypad7: return KC_KP_7;
        case kVK_ANSI_Keypad8: return KC_KP_8;
        case kVK_ANSI_Keypad9: return KC_KP_9;
        case kVK_ANSI_KeypadDecimal:  return KC_KP_DECIMAL;
        case kVK_ANSI_KeypadDivide:   return KC_KP_DIVIDE;
        case kVK_ANSI_KeypadMultiply: return KC_KP_MULTIPLY;
        case kVK_ANSI_KeypadMinus:    return KC_KP_MINUS;
        case kVK_ANSI_KeypadPlus:     return KC_KP_PLUS;
        case kVK_ANSI_KeypadEnter:    return KC_KP_ENTER;
        case kVK_ANSI_KeypadEquals:   return KC_KP_EQUAL;
        default:               return UINT16_MAX;
    }
}

static uint8_t buildMods(NSEventModifierFlags flags) {
    uint8_t m = 0;
    if (flags & NSEventModifierFlagShift)   m |= 1;
    if (flags & NSEventModifierFlagOption)  m |= 2;
    if (flags & NSEventModifierFlagControl) m |= 4;
    if (flags & NSEventModifierFlagCommand) m |= 8;
    return m;
}

typedef void (*AttyxExtendedKeyHandler)(uint16_t, uint8_t, uint8_t,
                                        uint32_t, uint32_t, uint32_t,
                                        const uint8_t*, int);

static uint32_t firstScalar(NSString* text) {
    NSUInteger length = text.length;
    if (length == 0) return 0;
    uint16_t first = [text characterAtIndex:0];
    uint16_t second = length > 1 ? [text characterAtIndex:1] : 0;
    return attyx_utf16_first_scalar(first, second, (int)MIN(length, 2));
}

static uint64_t deviceModifierMask(unsigned short keycode) {
    switch (keycode) {
        case kVK_Shift:        return 0x00000002;
        case kVK_RightShift:   return 0x00000004;
        case kVK_Control:      return 0x00000001;
        case kVK_RightControl: return 0x00002000;
        case kVK_Option:       return 0x00000020;
        case kVK_RightOption:  return 0x00000040;
        case kVK_Command:      return 0x00000008;
        case kVK_RightCommand: return 0x00000010;
        default:               return 0;
    }
}

static BOOL routeKittyAllKey(NSEvent* event, uint8_t eventType) {
    if (!(g_kitty_kbd_flags & 8)) return NO;

    uint16_t key = mapKeyCode(event.keyCode);
    uint32_t codepoint = 0;
    uint32_t shiftedCodepoint = 0;
    uint32_t baseCodepoint = 0;
    const uint8_t* textBytes = NULL;
    int textLength = 0;

    if (key == UINT16_MAX) {
        key = attyx_macos_modifier_key(event.keyCode);
    }

    if (key == UINT16_MAX) {
        key = KC_CODEPOINT;
        codepoint = firstScalar([event charactersByApplyingModifiers:0]);
        shiftedCodepoint = firstScalar(
            [event charactersByApplyingModifiers:NSEventModifierFlagShift]);
        baseCodepoint = attyx_macos_standard_codepoint(event.keyCode, 0);

        if (codepoint == 0) codepoint = baseCodepoint;
        if (codepoint == 0) return NO;
        if (shiftedCodepoint == codepoint) shiftedCodepoint = 0;
        if (baseCodepoint == codepoint) baseCodepoint = 0;

        if (eventType != 3) {
            NSString* generatedText = event.characters;
            const char* utf8 = generatedText.UTF8String;
            NSUInteger length = [generatedText lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (utf8 && length > 0 && length <= INT_MAX) {
                textBytes = (const uint8_t*)utf8;
                textLength = (int)length;
            }
        }
    }

    AttyxExtendedKeyHandler handler = g_popup_active
        ? attyx_popup_handle_key_ext
        : attyx_handle_key_ext;
    handler(key, buildMods(event.modifierFlags), eventType,
            codepoint, shiftedCodepoint, baseCodepoint,
            textBytes, textLength);
    return YES;
}

// Device-dependent modifier bits distinguishing the two physical Option keys.
#define ATTYX_LEFT_OPTION_MASK  0x20  // NX_DEVICELALTKEYMASK
#define ATTYX_RIGHT_OPTION_MASK 0x40  // NX_DEVICELRALTKEYMASK

// Whether the Option key in `flags` should act as Alt/Meta (emit an ESC-prefixed
// sequence) instead of composing a character (e.g. Option+ñ → ~ on a Spanish
// layout). Controlled by g_macos_option_as_alt: 0=none, 1=both, 2=left, 3=right.
static BOOL optionActsAsAlt(NSEventModifierFlags flags) {
    if (!(flags & NSEventModifierFlagOption)) return NO;
    switch (g_macos_option_as_alt) {
        case 1:  return YES;
        case 2:  return (flags & ATTYX_LEFT_OPTION_MASK) != 0;
        case 3:  return (flags & ATTYX_RIGHT_OPTION_MASK) != 0;
        default: return NO;
    }
}

// Build key + codepoint for keybind matching from an NSEvent.
static void eventToKeyCombo(NSEvent* event, uint16_t* outKey, uint32_t* outCp) {
    uint16_t mapped = mapKeyCode(event.keyCode);
    if (mapped != UINT16_MAX) {
        *outKey = mapped;
        *outCp = 0;
    } else {
        NSString* chars = event.charactersIgnoringModifiers;
        *outKey = KC_CODEPOINT;
        *outCp = (chars.length > 0) ? [chars characterAtIndex:0] : 0;
    }
}

@implementation AttyxView (Keyboard)

// Intercept Ctrl+Tab / Ctrl+Shift+Tab before macOS uses them for focus navigation
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (event.type != NSEventTypeKeyDown) return [super performKeyEquivalent:event];

    NSEventModifierFlags flags = event.modifierFlags;
    BOOL ctrl  = (flags & NSEventModifierFlagControl) != 0;

    if (ctrl && event.keyCode == kVK_Tab) {
        [self keyDown:event];
        return YES;
    }

    return [super performKeyEquivalent:event];
}

- (void)keyUp:(NSEvent *)event {
    // Only send key release when kitty event_types flag is active (bit 1)
    if (!(g_kitty_kbd_flags & 2)) return;

    if (event.modifierFlags & NSEventModifierFlagCommand) {
        uint16_t mapped = mapKeyCode(event.keyCode);
        if (mapped == KC_LEFT || mapped == KC_RIGHT) {
            uint16_t remapped = mapped == KC_LEFT ? KC_HOME : KC_END;
            void (*handle_key_fn)(uint16_t, uint8_t, uint8_t, uint32_t) =
                g_popup_active ? attyx_popup_handle_key : attyx_handle_key;
            handle_key_fn(remapped, 0, 3, 0);
        }
        return;
    }

    if (routeKittyAllKey(event, 3)) return;

    unsigned short kc = event.keyCode;
    uint16_t mapped = mapKeyCode(kc);
    uint8_t mods = buildMods(event.modifierFlags);

    void (*handle_key_fn)(uint16_t, uint8_t, uint8_t, uint32_t) =
        g_popup_active ? attyx_popup_handle_key : attyx_handle_key;

    if (mapped != UINT16_MAX) {
        handle_key_fn(mapped, mods, 3, 0);
    } else {
        uint32_t cp = firstScalar([event charactersByApplyingModifiers:0]);
        uint32_t shifted = firstScalar(
            [event charactersByApplyingModifiers:NSEventModifierFlagShift]);
        uint32_t base = attyx_macos_standard_codepoint(event.keyCode, 0);
        if (cp == 0) cp = base;
        if (cp == 0) return;
        if (shifted == cp) shifted = 0;
        if (base == cp) base = 0;
        AttyxExtendedKeyHandler ext_handler = g_popup_active
            ? attyx_popup_handle_key_ext
            : attyx_handle_key_ext;
        ext_handler(KC_CODEPOINT, mods, 3, cp, shifted, base, NULL, 0);
    }
}

- (void)flagsChanged:(NSEvent *)event {
    if (!(g_kitty_kbd_flags & 8)) return;

    uint16_t key = attyx_macos_modifier_key(event.keyCode);
    uint64_t mask = deviceModifierMask(event.keyCode);
    if (key == UINT16_MAX || mask == 0) return;

    uint8_t eventType = (event.modifierFlags & mask) ? 1 : 3;
    routeKittyAllKey(event, eventType);
}

- (void)snapViewportAndClearSelection {
    // Don't snap/clear when in copy mode — selection is keyboard-driven
    if (g_copy_mode) return;
    if (g_viewport_offset != 0) {
        g_viewport_offset = 0;
        attyx_mark_all_dirty();
    }
    if (g_sel_active) {
        g_sel_active = 0;
        attyx_mark_all_dirty();
    }
}

- (BOOL)handleSpecialKey:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags;
    BOOL ctrl  = (flags & NSEventModifierFlagControl) != 0;
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;
    BOOL cmd   = (flags & NSEventModifierFlagCommand) != 0;

    // Search bar key routing (before overlay actions, since search bar is an overlay)
    if (g_search_active) {
        unsigned short kc = event.keyCode;
        if (kc == kVK_Escape)                   { attyx_search_cmd(7); return YES; }
        if (kc == kVK_Return)                   { attyx_search_cmd(shift ? 9 : 8); return YES; }
        if (kc == kVK_Delete)                   { attyx_search_cmd(1); return YES; }
        if (kc == kVK_ForwardDelete)            { attyx_search_cmd(2); return YES; }
        if (kc == kVK_LeftArrow && !cmd)        { attyx_search_cmd(3); return YES; }
        if (kc == kVK_RightArrow && !cmd)       { attyx_search_cmd(4); return YES; }
        if (kc == kVK_LeftArrow && cmd)         { attyx_search_cmd(5); return YES; }
        if (kc == kVK_RightArrow && cmd)        { attyx_search_cmd(6); return YES; }
        if (kc == kVK_Home)                     { attyx_search_cmd(5); return YES; }
        if (kc == kVK_End)                      { attyx_search_cmd(6); return YES; }
        if (kc == kVK_UpArrow)                  { attyx_search_cmd(9); return YES; }
        if (kc == kVK_DownArrow)                { attyx_search_cmd(8); return YES; }
        if (ctrl && kc == kVK_ANSI_W)          { attyx_search_cmd(10); return YES; }
    }

    // AI edit prompt key routing
    if (g_ai_prompt_active) {
        unsigned short kc = event.keyCode;
        if (kc == kVK_Escape)                   { attyx_ai_prompt_cmd(7); return YES; }
        if (kc == kVK_Return)                   { attyx_ai_prompt_cmd(8); return YES; }
        if (kc == kVK_Delete)                   { attyx_ai_prompt_cmd(1); return YES; }
        if (kc == kVK_ForwardDelete)            { attyx_ai_prompt_cmd(2); return YES; }
        if (kc == kVK_LeftArrow)                { attyx_ai_prompt_cmd(3); return YES; }
        if (kc == kVK_RightArrow)               { attyx_ai_prompt_cmd(4); return YES; }
        if (kc == kVK_Home)                     { attyx_ai_prompt_cmd(5); return YES; }
        if (kc == kVK_End)                      { attyx_ai_prompt_cmd(6); return YES; }
    }

    // Session picker / command palette / theme picker / dashboard key routing
    if (g_session_picker_active || g_command_palette_active || g_theme_picker_active || g_tab_picker_active || g_agent_dashboard_active) {
        unsigned short kc = event.keyCode;
        if (kc == kVK_Escape)              { attyx_picker_cmd(7); return YES; }
        if (kc == kVK_Return)              { attyx_picker_cmd(8); return YES; }
        if (kc == kVK_Delete)              { attyx_picker_cmd(1); return YES; }
        if (kc == kVK_ForwardDelete)       { attyx_picker_cmd(1); return YES; }
        if (kc == kVK_UpArrow)             { attyx_picker_cmd(9); return YES; }
        if (kc == kVK_DownArrow)           { attyx_picker_cmd(10); return YES; }
        if (ctrl && kc == kVK_ANSI_R)      { attyx_picker_cmd(11); return YES; }
        if (ctrl && kc == kVK_ANSI_X)      { attyx_picker_cmd(12); return YES; }
        if (ctrl && kc == kVK_ANSI_U)      { attyx_picker_cmd(13); return YES; }
        if (ctrl && kc == kVK_ANSI_D)      { attyx_picker_cmd(14); return YES; }
        if (ctrl && kc == kVK_ANSI_W)      { attyx_picker_cmd(15); return YES; }
        if (ctrl && kc == kVK_ANSI_C)      { attyx_picker_cmd(7); return YES; }
        // Printable chars fall through to IME handler
        return NO;
    }

    // Overlay interaction keys (contextual, not user-configurable)
    if (g_overlay_has_actions) {
        unsigned short kc = event.keyCode;
        if (kc == kVK_Escape) {
            attyx_overlay_esc();
            return YES;
        }
        if (kc == kVK_Tab && !ctrl && !shift) {
            attyx_overlay_tab();
            return YES;
        }
        if (kc == kVK_Tab && shift && !ctrl) {
            attyx_overlay_shift_tab();
            return YES;
        }
        if (kc == kVK_Return && !ctrl && !shift) {
            attyx_overlay_enter();
            return YES;
        }
    }

    // Copy/visual mode: intercept all keys when active
    if (g_copy_mode) {
        uint16_t vmKey; uint32_t vmCp;
        eventToKeyCombo(event, &vmKey, &vmCp);
        uint8_t vmMods = buildMods(flags);
        if (attyx_copy_mode_key(vmKey, vmMods, vmCp)) return YES;
    }

    // Configurable keybind match (covers all user-bindable actions:
    // hotkeys, scrollback, popups, sequences, etc.)
    {
        uint16_t matchKey; uint32_t matchCp;
        eventToKeyCombo(event, &matchKey, &matchCp);
        uint8_t mods = buildMods(flags);
        uint8_t action = attyx_keybind_match(matchKey, mods, matchCp);
        if (action != ATTYX_ACTION_NONE && attyx_dispatch_action(action))
            return YES;
    }

    // Any input past this point goes to the PTY — snap viewport to bottom
    // so the user sees what they're typing. (Keybinds like scroll_page_up
    // already returned YES above, so they won't trigger this.)
    [self snapViewportAndClearSelection];

    // Shift+Enter / Alt+Enter: legacy fallback only.
    // When Kitty keyboard protocol is active, the encoder reports modifiers
    // properly (e.g. CSI 13;2u for Shift+Enter), so apps like Claude Code
    // can distinguish them natively. Only send raw sequences in legacy mode.
    if (!g_kitty_kbd_flags && mapKeyCode(event.keyCode) == KC_ENTER) {
        if (shift && !cmd && !ctrl && !(flags & NSEventModifierFlagOption)) {
            const uint8_t nl = '\n';
            void (*send_fn)(const uint8_t*, int) =
                g_popup_active ? attyx_popup_send_input : attyx_send_input;
            send_fn(&nl, 1);
            return YES;
        }
        if ((flags & NSEventModifierFlagOption) && !cmd && !ctrl && !shift) {
            const uint8_t seq[2] = { 0x1b, '\r' };
            void (*send_fn)(const uint8_t*, int) =
                g_popup_active ? attyx_popup_send_input : attyx_send_input;
            send_fn(seq, 2);
            return YES;
        }
    }

    // Alt+Arrow: send word movement sequences (ESC b / ESC f) in legacy mode.
    // When Kitty protocol is active, let the encoder send proper CSI with
    // modifier bits so apps get the real Alt+Arrow info.
    if (!g_kitty_kbd_flags && (flags & NSEventModifierFlagOption) && !cmd && !ctrl) {
        uint16_t mapped = mapKeyCode(event.keyCode);
        if (mapped == KC_LEFT || mapped == KC_RIGHT) {
            const uint8_t *seq = (mapped == KC_LEFT)
                ? (const uint8_t *)"\x1b" "b" : (const uint8_t *)"\x1b" "f";
            void (*send_fn)(const uint8_t*, int) =
                g_popup_active ? attyx_popup_send_input : attyx_send_input;
            send_fn(seq, 2);
            return YES;
        }
    }

    // Cmd+Arrow: remap to Home/End for standard terminal line-navigation
    if (cmd) {
        uint16_t mapped = mapKeyCode(event.keyCode);
        if (mapped == KC_LEFT || mapped == KC_RIGHT) {
            uint16_t remapped = (mapped == KC_LEFT) ? KC_HOME : KC_END;
            uint8_t et = event.isARepeat ? 2 : 1;
            void (*handle_key_fn)(uint16_t, uint8_t, uint8_t, uint32_t) =
                g_popup_active ? attyx_popup_handle_key : attyx_handle_key;
            handle_key_fn(remapped, 0, et, 0);
            return YES;
        }
        // Forward remaining Cmd keys to system menu (Cmd+Q, Cmd+H, etc.)
        [super keyDown:event];
        return YES;
    }

    unsigned short kc = event.keyCode;
    uint16_t mapped = mapKeyCode(kc);
    uint8_t mods = buildMods(flags);
    uint8_t et = event.isARepeat ? 2 : 1;

    if (routeKittyAllKey(event, et)) return YES;

    // Route special keys to popup or main terminal
    void (*handle_key_fn)(uint16_t, uint8_t, uint8_t, uint32_t) =
        g_popup_active ? attyx_popup_handle_key : attyx_handle_key;

    // Special keys handled by the encoder
    if (mapped != UINT16_MAX) {
        handle_key_fn(mapped, mods, et, 0);
        return YES;
    }

    // Ctrl+key or Alt+key with a character. When Option does NOT act as Alt
    // (the default), let the key fall through to interpretKeyEvents so macOS
    // composes the layout's character (e.g. Option+ñ → ~) instead of emitting
    // an ESC-prefixed Meta sequence.
    if (ctrl || optionActsAsAlt(flags)) {
        uint32_t cp = firstScalar([event charactersByApplyingModifiers:0]);
        uint32_t shifted = firstScalar(
            [event charactersByApplyingModifiers:NSEventModifierFlagShift]);
        uint32_t base = attyx_macos_standard_codepoint(event.keyCode, 0);
        if (cp == 0) cp = base;
        if (shifted == cp) shifted = 0;
        if (base == cp) base = 0;
        if (cp != 0) {
            AttyxExtendedKeyHandler ext_handler = g_popup_active
                ? attyx_popup_handle_key_ext
                : attyx_handle_key_ext;
            ext_handler(KC_CODEPOINT, mods, et, cp, shifted, base, NULL, 0);
            return YES;
        }
        if (ctrl) return YES;
    }

    return NO;
}

- (void)keyDown:(NSEvent *)event {
    // When popup is active, route ALL input to popup (except keybinds)
    if (g_popup_active) {
        if ([self handleSpecialKey:event]) return;
        [self interpretKeyEvents:@[event]];
        return;
    }

    NSEventModifierFlags flags = event.modifierFlags;
    BOOL cmd = (flags & NSEventModifierFlagCommand) != 0;

    if ([self hasMarkedText]) {
        [self snapViewportAndClearSelection];
        if (cmd) {
            [super keyDown:event];
            return;
        }
        [self interpretKeyEvents:@[event]];
        return;
    }

    // Handle special keys (keybinds, overlays, search) BEFORE clearing
    // selection — the AI edit keybind needs to see g_sel_active.
    if ([self handleSpecialKey:event]) return;

    // In copy mode, suppress all remaining input (no IME, no PTY)
    if (g_copy_mode) return;

    [self snapViewportAndClearSelection];

    // Repeat bypass: send repeated character keys directly to the encoder,
    // skipping interpretKeyEvents (which would trigger the accent picker).
    if (event.isARepeat) {
        NSString* chars = event.characters;
        if (chars.length > 0) {
            uint32_t cp = [chars characterAtIndex:0];
            uint8_t mods = buildMods(event.modifierFlags);
            void (*handle_key_fn)(uint16_t, uint8_t, uint8_t, uint32_t) =
                g_popup_active ? attyx_popup_handle_key : attyx_handle_key;
            handle_key_fn(KC_CODEPOINT, mods, 2, cp);
            return;
        }
    }

    [self interpretKeyEvents:@[event]];
}

@end
