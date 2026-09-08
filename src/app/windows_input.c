// Attyx — Windows keyboard + IME input handling
// Keyboard events, character input, IME composition, and WndProc dispatcher.

#ifdef _WIN32

#include "windows_internal.h"

// ---------------------------------------------------------------------------
// KeyCode enum values (must match src/term/key_encode.zig KeyCode)
// ---------------------------------------------------------------------------

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

// Suppress WM_CHAR after handled WM_KEYDOWN
int g_suppress_char = 0;
static int g_altgr_control_suppressed = 0;

typedef struct {
    uint32_t codepoint;
    uint32_t shifted_codepoint;
    uint32_t base_codepoint;
    uint8_t text[32];
    int text_len;
    int char_messages;
} WinPrintableIdentity;

// ---------------------------------------------------------------------------
// VK_* -> KeyCode mapping
// ---------------------------------------------------------------------------

uint16_t win_mapVirtualKey(WPARAM vk, LPARAM lParam) {
    BOOL extended = (lParam & (1 << 24)) != 0;
    (void)extended; // used only for VK_RETURN below
    switch (vk) {
        case VK_UP:       return KC_UP;
        case VK_DOWN:     return KC_DOWN;
        case VK_RIGHT:    return KC_RIGHT;
        case VK_LEFT:     return KC_LEFT;
        case VK_HOME:     return KC_HOME;
        case VK_END:      return KC_END;
        case VK_PRIOR:    return KC_PAGE_UP;
        case VK_NEXT:     return KC_PAGE_DOWN;
        case VK_INSERT:   return KC_INSERT;
        case VK_DELETE:   return KC_DELETE;
        case VK_BACK:     return KC_BACKSPACE;
        case VK_RETURN:   return (lParam & (1 << 24)) ? KC_KP_ENTER : KC_ENTER;
        case VK_TAB:      return KC_TAB;
        case VK_ESCAPE:   return KC_ESCAPE;
        case VK_F1:       return KC_F1;
        case VK_F2:       return KC_F2;
        case VK_F3:       return KC_F3;
        case VK_F4:       return KC_F4;
        case VK_F5:       return KC_F5;
        case VK_F6:       return KC_F6;
        case VK_F7:       return KC_F7;
        case VK_F8:       return KC_F8;
        case VK_F9:       return KC_F9;
        case VK_F10:      return KC_F10;
        case VK_F11:      return KC_F11;
        case VK_F12:      return KC_F12;
        case VK_NUMPAD0:  return KC_KP_0;
        case VK_NUMPAD1:  return KC_KP_1;
        case VK_NUMPAD2:  return KC_KP_2;
        case VK_NUMPAD3:  return KC_KP_3;
        case VK_NUMPAD4:  return KC_KP_4;
        case VK_NUMPAD5:  return KC_KP_5;
        case VK_NUMPAD6:  return KC_KP_6;
        case VK_NUMPAD7:  return KC_KP_7;
        case VK_NUMPAD8:  return KC_KP_8;
        case VK_NUMPAD9:  return KC_KP_9;
        case VK_DECIMAL:  return KC_KP_DECIMAL;
        case VK_DIVIDE:   return KC_KP_DIVIDE;
        case VK_MULTIPLY: return KC_KP_MULTIPLY;
        case VK_SUBTRACT: return KC_KP_MINUS;
        case VK_ADD:      return KC_KP_PLUS;
        default:          return UINT16_MAX;
    }
}

static uint16_t winMapAllKeyVirtualKey(WPARAM vk, LPARAM lParam) {
    if (!(lParam & (1L << 24))) {
        UINT scan_code = (((UINT_PTR)lParam >> 16) & 0xFF);
        switch (vk) {
            case VK_INSERT: if (scan_code == 0x52) return KC_KP_0; break;
            case VK_END:    if (scan_code == 0x4F) return KC_KP_1; break;
            case VK_DOWN:   if (scan_code == 0x50) return KC_KP_2; break;
            case VK_NEXT:   if (scan_code == 0x51) return KC_KP_3; break;
            case VK_LEFT:   if (scan_code == 0x4B) return KC_KP_4; break;
            case VK_CLEAR:  if (scan_code == 0x4C) return KC_KP_5; break;
            case VK_RIGHT:  if (scan_code == 0x4D) return KC_KP_6; break;
            case VK_HOME:   if (scan_code == 0x47) return KC_KP_7; break;
            case VK_UP:     if (scan_code == 0x48) return KC_KP_8; break;
            case VK_PRIOR:  if (scan_code == 0x49) return KC_KP_9; break;
            case VK_DELETE: if (scan_code == 0x53) return KC_KP_DECIMAL; break;
            default: break;
        }
    }
    return win_mapVirtualKey(vk, lParam);
}

// Detect AltGr: Windows sends left-Ctrl + right-Alt for AltGr.
// Returns true when the "Ctrl" is just a phantom from AltGr.
static int win_isAltGr(void) {
    return (GetKeyState(VK_RMENU) & 0x8000) &&
           (GetKeyState(VK_LCONTROL) & 0x8000) &&
           !(GetKeyState(VK_RCONTROL) & 0x8000);
}

// Build modifier bitmask: bit0=shift, bit1=alt, bit2=ctrl, bit3=super
uint8_t win_buildMods(void) {
    uint8_t m = 0;
    if (GetKeyState(VK_SHIFT)   & 0x8000) m |= 1;
    if (GetKeyState(VK_MENU)    & 0x8000) m |= 2;
    if (GetKeyState(VK_CONTROL) & 0x8000) m |= 4;
    if (GetKeyState(VK_LWIN) & 0x8000 || GetKeyState(VK_RWIN) & 0x8000) m |= 8;
    // Strip phantom Ctrl from AltGr so alt+key bindings work with right-Alt
    if (win_isAltGr() && (m & 6) == 6) m &= ~4;
    return m;
}

static UINT winMessageScanCode(LPARAM lParam) {
    UINT scan_code = ((UINT_PTR)lParam >> 16) & 0xFF;
    if (lParam & (1L << 24)) scan_code |= 0xE000;
    return scan_code;
}

static UINT winSideSpecificVirtualKey(WPARAM vk, LPARAM lParam) {
    UINT normalized = (UINT)vk;
    if (normalized == VK_SHIFT || normalized == VK_CONTROL || normalized == VK_MENU) {
        UINT side_specific = MapVirtualKeyW(winMessageScanCode(lParam), MAPVK_VSC_TO_VK_EX);
        if (side_specific != 0) normalized = side_specific;
    }
    return normalized;
}

static uint16_t win_mapModifierKey(WPARAM vk, LPARAM lParam) {
    switch (winSideSpecificVirtualKey(vk, lParam)) {
        case VK_LSHIFT:   return KC_LEFT_SHIFT;
        case VK_LCONTROL: return KC_LEFT_CONTROL;
        case VK_LMENU:    return KC_LEFT_ALT;
        case VK_LWIN:     return KC_LEFT_SUPER;
        case VK_RSHIFT:   return KC_RIGHT_SHIFT;
        case VK_RCONTROL: return KC_RIGHT_CONTROL;
        case VK_RMENU:    return KC_RIGHT_ALT;
        case VK_RWIN:     return KC_RIGHT_SUPER;
        default:          return UINT16_MAX;
    }
}

static int winIsAltGrControlPrefix(WPARAM vk, LPARAM lParam) {
    if (winSideSpecificVirtualKey(vk, lParam) != VK_LCONTROL) return 0;

    MSG next;
    if (!PeekMessageW(&next, NULL, WM_KEYFIRST, WM_KEYLAST, PM_NOREMOVE))
        return 0;
    return (next.message == WM_KEYDOWN || next.message == WM_SYSKEYDOWN) &&
           (next.wParam == VK_MENU || next.wParam == VK_RMENU) &&
           (next.lParam & (1L << 24)) != 0 &&
           next.time == (DWORD)GetMessageTime();
}

static uint32_t winStandardCodepoint(LPARAM lParam, int shifted) {
    static const char number_row[] = "1234567890";
    static const char shifted_numbers[] = "!@#$%^&*()";
    static const char top_row[] = "qwertyuiop";
    static const char home_row[] = "asdfghjkl";
    static const char bottom_row[] = "zxcvbnm";
    UINT scan_code = (((UINT_PTR)lParam >> 16) & 0xFF);

    if (scan_code >= 0x02 && scan_code <= 0x0B) {
        size_t index = scan_code - 0x02;
        return shifted ? (uint32_t)shifted_numbers[index]
                       : (uint32_t)number_row[index];
    }
    if (scan_code >= 0x10 && scan_code <= 0x19) {
        uint32_t codepoint = (uint32_t)top_row[scan_code - 0x10];
        return shifted ? codepoint - 'a' + 'A' : codepoint;
    }
    if (scan_code >= 0x1E && scan_code <= 0x26) {
        uint32_t codepoint = (uint32_t)home_row[scan_code - 0x1E];
        return shifted ? codepoint - 'a' + 'A' : codepoint;
    }
    if (scan_code >= 0x2C && scan_code <= 0x32) {
        uint32_t codepoint = (uint32_t)bottom_row[scan_code - 0x2C];
        return shifted ? codepoint - 'a' + 'A' : codepoint;
    }
    switch (scan_code) {
        case 0x0C: return shifted ? '_' : '-';
        case 0x0D: return shifted ? '+' : '=';
        case 0x1A: return shifted ? '{' : '[';
        case 0x1B: return shifted ? '}' : ']';
        case 0x27: return shifted ? ':' : ';';
        case 0x28: return shifted ? '"' : '\'';
        case 0x29: return shifted ? '~' : '`';
        case 0x2B: return shifted ? '|' : '\\';
        case 0x33: return shifted ? '<' : ',';
        case 0x34: return shifted ? '>' : '.';
        case 0x35: return shifted ? '?' : '/';
        case 0x39: return ' ';
        default:   return 0;
    }
}

static uint32_t winFirstUtf16Scalar(const WCHAR* text, int length) {
    if (length <= 0 || text[0] == 0) return 0;
    uint32_t first = (uint16_t)text[0];
    if (first >= 0xD800 && first <= 0xDBFF) {
        if (length < 2) return 0;
        uint32_t second = (uint16_t)text[1];
        if (second < 0xDC00 || second > 0xDFFF) return 0;
        return 0x10000u + ((first - 0xD800u) << 10) + (second - 0xDC00u);
    }
    if (first >= 0xDC00 && first <= 0xDFFF) return 0;
    return first;
}

static int winUtf16TextIsPrintable(const WCHAR* text, int length) {
    int offset = 0;
    while (offset < length) {
        uint32_t codepoint = winFirstUtf16Scalar(text + offset, length - offset);
        if (codepoint == 0 || codepoint < 0x20 ||
            (codepoint >= 0x7F && codepoint <= 0x9F))
            return 0;
        offset += codepoint > 0xFFFF ? 2 : 1;
    }
    return 1;
}

static int winTranslateVirtualKey(WPARAM vk, LPARAM lParam, const BYTE state[256],
                                  WCHAR* output, int capacity, int* dead) {
    UINT scan_code = (((UINT_PTR)lParam >> 16) & 0xFF);
    int result = ToUnicodeEx((UINT)vk, scan_code, state, output, capacity, 4,
                             GetKeyboardLayout(0));
    *dead = result < 0;
    return result < 0 ? -result : result;
}

static int buildWinPrintableIdentity(WPARAM vk, LPARAM lParam, int include_text,
                                     WinPrintableIdentity* identity) {
    memset(identity, 0, sizeof(*identity));

    BYTE neutral_state[256] = {0};
    WCHAR translated[8] = {0};
    int dead = 0;
    int translated_len = winTranslateVirtualKey(vk, lParam, neutral_state,
                                                 translated, 8, &dead);
    uint32_t codepoint = winFirstUtf16Scalar(translated, translated_len);
    uint32_t base_codepoint = winStandardCodepoint(lParam, 0);
    if (codepoint == 0) codepoint = base_codepoint;
    if (codepoint == 0) return 0;
    if (codepoint >= 'A' && codepoint <= 'Z')
        codepoint = codepoint - 'A' + 'a';

    BYTE shifted_state[256] = {0};
    shifted_state[VK_SHIFT] = 0x80;
    shifted_state[VK_LSHIFT] = 0x80;
    memset(translated, 0, sizeof(translated));
    translated_len = winTranslateVirtualKey(vk, lParam, shifted_state,
                                             translated, 8, &dead);
    uint32_t shifted_codepoint = winFirstUtf16Scalar(translated, translated_len);
    if (shifted_codepoint == 0 && base_codepoint == codepoint)
        shifted_codepoint = winStandardCodepoint(lParam, 1);
    if (shifted_codepoint == codepoint) shifted_codepoint = 0;
    if (base_codepoint == codepoint) base_codepoint = 0;

    identity->codepoint = codepoint;
    identity->shifted_codepoint = shifted_codepoint;
    identity->base_codepoint = base_codepoint;

    if (!include_text || g_ime_composing) return 1;
    BYTE actual_state[256];
    if (!GetKeyboardState(actual_state)) return 1;
    memset(translated, 0, sizeof(translated));
    translated_len = winTranslateVirtualKey(vk, lParam, actual_state,
                                             translated, 8, &dead);
    if (dead || translated_len <= 0) return 1;
    if (translated_len > 8) translated_len = 8;
    identity->char_messages = translated_len;
    if (!winUtf16TextIsPrintable(translated, translated_len)) return 1;
    identity->text_len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                              translated, translated_len,
                                              (char*)identity->text,
                                              (int)sizeof(identity->text),
                                              NULL, NULL);
    return 1;
}

static void dispatchWinKeyExt(uint16_t key, uint8_t mods, uint8_t event_type,
                              uint32_t codepoint, uint32_t shifted_codepoint,
                              uint32_t base_codepoint, const uint8_t* text,
                              int text_len) {
    if (g_popup_active) {
        attyx_popup_handle_key_ext(key, mods, event_type, codepoint,
                                   shifted_codepoint, base_codepoint,
                                   text, text_len);
    } else {
        attyx_handle_key_ext(key, mods, event_type, codepoint,
                            shifted_codepoint, base_codepoint,
                            text, text_len);
    }
}

static int routeWinAllKey(WPARAM vk, LPARAM lParam, uint8_t event_type) {
    if (!(g_kitty_kbd_flags & 8)) return 0;

    UINT side_specific = winSideSpecificVirtualKey(vk, lParam);
    if (side_specific == VK_LCONTROL) {
        if (event_type != 3 &&
            (g_altgr_control_suppressed || winIsAltGrControlPrefix(vk, lParam))) {
            g_altgr_control_suppressed = 1;
            g_suppress_char = 0;
            return 1;
        }
        if (event_type == 3 && g_altgr_control_suppressed) {
            g_altgr_control_suppressed = 0;
            g_suppress_char = 0;
            return 1;
        }
    }

    uint8_t mods = win_buildMods();
    if (g_altgr_control_suppressed) mods &= ~4;
    uint16_t mapped = winMapAllKeyVirtualKey(vk, lParam);
    if (mapped != UINT16_MAX) {
        dispatchWinKeyExt(mapped, mods, event_type, 0, 0, 0, NULL, 0);
        g_suppress_char = event_type == 3 ? 0 : 1;
        return 1;
    }

    uint16_t modifier = win_mapModifierKey(vk, lParam);
    if (modifier != UINT16_MAX) {
        dispatchWinKeyExt(modifier, mods, event_type, 0, 0, 0, NULL, 0);
        g_suppress_char = 0;
        return 1;
    }

    WinPrintableIdentity identity;
    if (!buildWinPrintableIdentity(vk, lParam, event_type != 3, &identity))
        return 0;
    dispatchWinKeyExt(KC_CODEPOINT, mods, event_type, identity.codepoint,
                      identity.shifted_codepoint, identity.base_codepoint,
                      identity.text_len > 0 ? identity.text : NULL,
                      identity.text_len);
    g_suppress_char = event_type == 3 ? 0 : identity.char_messages;
    return 1;
}

// Build key + codepoint for keybind matching from a virtual key.
void win_vkToKeyCombo(WPARAM vk, LPARAM lParam, uint16_t* outKey, uint32_t* outCp) {
    uint16_t mapped = win_mapVirtualKey(vk, lParam);
    if (mapped != UINT16_MAX) {
        *outKey = mapped;
        *outCp = 0;
    } else if (vk >= 'A' && vk <= 'Z') {
        *outKey = KC_CODEPOINT;
        uint32_t cp = 'a' + (uint32_t)(vk - 'A');
        if (GetKeyState(VK_SHIFT) & 0x8000) cp -= 32;
        *outCp = cp;
    } else if (vk >= '0' && vk <= '9') {
        *outKey = KC_CODEPOINT;
        *outCp = '0' + (uint32_t)(vk - '0');
    } else if (vk == VK_SPACE) {
        *outKey = KC_CODEPOINT;
        *outCp = ' ';
    } else {
        // OEM keys → ASCII codepoints for keybind matching
        *outKey = KC_CODEPOINT;
        switch (vk) {
            case VK_OEM_1:      *outCp = ';'; break;   // ;:
            case VK_OEM_PLUS:   *outCp = '='; break;   // =+
            case VK_OEM_COMMA:  *outCp = ','; break;   // ,<
            case VK_OEM_MINUS:  *outCp = '-'; break;   // -_
            case VK_OEM_PERIOD: *outCp = '.'; break;   // .>
            case VK_OEM_2:      *outCp = '/'; break;   // /?
            case VK_OEM_3:      *outCp = '`'; break;   // `~
            case VK_OEM_4:      *outCp = '['; break;   // [{
            case VK_OEM_5:      *outCp = '\\'; break;  // \|
            case VK_OEM_6:      *outCp = ']'; break;   // ]}
            case VK_OEM_7:      *outCp = '\''; break;  // '"
            default:            *outCp = 0; break;
        }
    }
}

void win_snapViewport(void) {
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

// ---------------------------------------------------------------------------
// Keyboard handling — WM_KEYDOWN / WM_SYSKEYDOWN
// ---------------------------------------------------------------------------

static LRESULT handleKeyDown(HWND hwnd, WPARAM vk, LPARAM lParam) {
    (void)hwnd;
    int isRepeat = (lParam & (1 << 30)) != 0;
    g_suppress_char = 0;

    int ctrl  = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
    int alt   = (GetKeyState(VK_MENU)    & 0x8000) != 0;
    int shift = (GetKeyState(VK_SHIFT)   & 0x8000) != 0;
    // Strip phantom Ctrl from AltGr (right-Alt sends Ctrl+Alt on Windows)
    if (win_isAltGr() && ctrl && alt) ctrl = 0;

    // Overlay interaction keys (contextual, not user-configurable)
    if (g_overlay_has_actions) {
        if (vk == VK_ESCAPE)                         { attyx_overlay_esc(); g_suppress_char = 1; return 0; }
        if (vk == VK_TAB && !ctrl && !shift && !alt) { attyx_overlay_tab(); g_suppress_char = 1; return 0; }
        if (vk == VK_TAB && shift && !ctrl && !alt)  { attyx_overlay_shift_tab(); g_suppress_char = 1; return 0; }
        if (vk == VK_RETURN && !ctrl && !shift && !alt) { attyx_overlay_enter(); g_suppress_char = 1; return 0; }
    }

    // Copy/visual mode: intercept all keys when active
    if (g_copy_mode) {
        uint16_t vmKey; uint32_t vmCp;
        win_vkToKeyCombo(vk, lParam, &vmKey, &vmCp);
        uint8_t vmMods = win_buildMods();
        if (attyx_copy_mode_key(vmKey, vmMods, vmCp)) {
            g_suppress_char = 1;
            return 0;
        }
    }

    // Configurable keybind match
    {
        uint16_t matchKey; uint32_t matchCp;
        win_vkToKeyCombo(vk, lParam, &matchKey, &matchCp);
        uint8_t m = win_buildMods();
        uint8_t act = attyx_keybind_match(matchKey, m, matchCp);
        if (act != ATTYX_ACTION_NONE && attyx_dispatch_action(act)) {
            g_suppress_char = 1;
            return 0;
        }
    }

    // Any input past this point goes to the PTY — snap viewport
    win_snapViewport();

    // Shift+Enter / Alt+Enter: legacy fallback
    if (!g_kitty_kbd_flags && win_mapVirtualKey(vk, lParam) == KC_ENTER) {
        if (shift && !alt && !ctrl) {
            const uint8_t nl = '\n';
            void (*send_fn)(const uint8_t*, int) =
                g_popup_active ? attyx_popup_send_input : attyx_send_input;
            send_fn(&nl, 1);
            g_suppress_char = 1;
            return 0;
        }
        if (alt && !ctrl && !shift) {
            const uint8_t seq[2] = { 0x1b, '\r' };
            void (*send_fn)(const uint8_t*, int) =
                g_popup_active ? attyx_popup_send_input : attyx_send_input;
            send_fn(seq, 2);
            g_suppress_char = 1;
            return 0;
        }
    }

    // Alt+Arrow: word movement in legacy mode
    if (!g_kitty_kbd_flags && alt && !ctrl) {
        if (vk == VK_LEFT || vk == VK_RIGHT) {
            const uint8_t *seq = (vk == VK_LEFT)
                ? (const uint8_t *)"\x1b" "b" : (const uint8_t *)"\x1b" "f";
            void (*send_fn)(const uint8_t*, int) =
                g_popup_active ? attyx_popup_send_input : attyx_send_input;
            send_fn(seq, 2);
            g_suppress_char = 1;
            return 0;
        }
    }

    // Search bar key routing
    if (g_search_active) {
        if (vk == VK_ESCAPE)    { attyx_search_cmd(7); g_suppress_char = 1; return 0; }
        if (vk == VK_RETURN)    { attyx_search_cmd(shift ? 9 : 8); g_suppress_char = 1; return 0; }
        if (vk == VK_BACK)      { attyx_search_cmd(1); g_suppress_char = 1; return 0; }
        if (vk == VK_DELETE)    { attyx_search_cmd(2); g_suppress_char = 1; return 0; }
        if (vk == VK_LEFT)      { attyx_search_cmd(3); g_suppress_char = 1; return 0; }
        if (vk == VK_RIGHT)     { attyx_search_cmd(4); g_suppress_char = 1; return 0; }
        if (vk == VK_HOME)      { attyx_search_cmd(5); g_suppress_char = 1; return 0; }
        if (vk == VK_END)       { attyx_search_cmd(6); g_suppress_char = 1; return 0; }
        if (vk == VK_UP)        { attyx_search_cmd(9); g_suppress_char = 1; return 0; }
        if (vk == VK_DOWN)      { attyx_search_cmd(8); g_suppress_char = 1; return 0; }
        if (ctrl && vk == 'W')  { attyx_search_cmd(10); g_suppress_char = 1; return 0; }
        g_suppress_char = 0;
        return 0;
    }

    // AI edit prompt key routing
    if (g_ai_prompt_active) {
        if (vk == VK_ESCAPE)    { attyx_ai_prompt_cmd(7); g_suppress_char = 1; return 0; }
        if (vk == VK_RETURN)    { attyx_ai_prompt_cmd(8); g_suppress_char = 1; return 0; }
        if (vk == VK_BACK)      { attyx_ai_prompt_cmd(1); g_suppress_char = 1; return 0; }
        if (vk == VK_DELETE)    { attyx_ai_prompt_cmd(2); g_suppress_char = 1; return 0; }
        if (vk == VK_LEFT)      { attyx_ai_prompt_cmd(3); g_suppress_char = 1; return 0; }
        if (vk == VK_RIGHT)     { attyx_ai_prompt_cmd(4); g_suppress_char = 1; return 0; }
        if (vk == VK_HOME)      { attyx_ai_prompt_cmd(5); g_suppress_char = 1; return 0; }
        if (vk == VK_END)       { attyx_ai_prompt_cmd(6); g_suppress_char = 1; return 0; }
        g_suppress_char = 0;
        return 0;
    }

    // Session picker / command palette / theme picker key routing
    if (g_session_picker_active || g_command_palette_active || g_theme_picker_active || g_shell_picker_active) {
        if (vk == VK_ESCAPE)     { attyx_picker_cmd(7); g_suppress_char = 1; return 0; }
        if (vk == VK_RETURN)     { attyx_picker_cmd(8); g_suppress_char = 1; return 0; }
        if (vk == VK_BACK)       { attyx_picker_cmd(1); g_suppress_char = 1; return 0; }
        if (vk == VK_DELETE)     { attyx_picker_cmd(1); g_suppress_char = 1; return 0; }
        if (vk == VK_UP)         { attyx_picker_cmd(9); g_suppress_char = 1; return 0; }
        if (vk == VK_DOWN)       { attyx_picker_cmd(10); g_suppress_char = 1; return 0; }
        if (ctrl && vk == 'R')   { attyx_picker_cmd(11); g_suppress_char = 1; return 0; }
        if (ctrl && vk == 'X')   { attyx_picker_cmd(12); g_suppress_char = 1; return 0; }
        if (ctrl && vk == 'U')   { attyx_picker_cmd(13); g_suppress_char = 1; return 0; }
        if (ctrl && vk == 'D')   { attyx_picker_cmd(14); g_suppress_char = 1; return 0; }
        if (ctrl && vk == 'W')   { attyx_picker_cmd(15); g_suppress_char = 1; return 0; }
        if (ctrl && vk == 'C')   { attyx_picker_cmd(7); g_suppress_char = 1; return 0; }
        g_suppress_char = 0;
        return 0;
    }

    if (routeWinAllKey(vk, lParam, isRepeat ? 2 : 1)) return 0;

    // Route to popup when active
    if (g_popup_active) {
        uint16_t mapped = win_mapVirtualKey(vk, lParam);
        uint8_t m = win_buildMods();
        uint8_t et = isRepeat ? 2 : 1;
        if (mapped != UINT16_MAX) {
            attyx_popup_handle_key(mapped, m, et, 0);
            g_suppress_char = 1;
        } else if (vk >= 'A' && vk <= 'Z') {
            uint32_t cp = 'a' + (uint32_t)(vk - 'A');
            if (shift) cp -= 32;
            attyx_popup_handle_key(KC_CODEPOINT, m, et, cp);
            g_suppress_char = 1;
        } else if ((ctrl || alt) && vk >= '0' && vk <= '9') {
            attyx_popup_handle_key(KC_CODEPOINT, m, et, (uint32_t)vk);
            g_suppress_char = 1;
        } else {
            // Let WM_CHAR handle space, digits, quotes, punctuation, etc.
            g_suppress_char = 0;
        }
        return 0;
    }

    // Modifier-only keys: don't clear selection
    if (vk == VK_SHIFT || vk == VK_CONTROL || vk == VK_MENU ||
        vk == VK_LSHIFT || vk == VK_RSHIFT ||
        vk == VK_LCONTROL || vk == VK_RCONTROL ||
        vk == VK_LMENU || vk == VK_RMENU ||
        vk == VK_LWIN || vk == VK_RWIN)
        return 0;

    win_snapViewport();

    // Map special keys through the encoder
    uint16_t mapped = win_mapVirtualKey(vk, lParam);
    uint8_t m = win_buildMods();
    uint8_t et = isRepeat ? 2 : 1;

    if (mapped != UINT16_MAX) {
        attyx_handle_key(mapped, m, et, 0);
        g_suppress_char = 1;
        return 0;
    }

    // Ctrl+key or Alt+key with a letter
    if ((ctrl || alt) && vk >= 'A' && vk <= 'Z') {
        uint32_t cp = 'a' + (uint32_t)(vk - 'A');
        if (shift) cp -= 32;
        attyx_handle_key(KC_CODEPOINT, m, et, cp);
        g_suppress_char = 1;
        return 0;
    }

    // Alt+digit (tab switching, etc.)
    if (alt && vk >= '0' && vk <= '9') {
        uint32_t cp = (uint32_t)vk;
        attyx_handle_key(KC_CODEPOINT, m, et, cp);
        g_suppress_char = 1;
        return 0;
    }

    // Modifier+punctuation (Ctrl+[, Alt+-, Ctrl+Alt+=, etc.)
    if (ctrl || alt) {
        uint32_t cp = 0;
        switch (vk) {
            case VK_OEM_1:      cp = ';'; break;
            case VK_OEM_PLUS:   cp = '='; break;
            case VK_OEM_COMMA:  cp = ','; break;
            case VK_OEM_MINUS:  cp = '-'; break;
            case VK_OEM_PERIOD: cp = '.'; break;
            case VK_OEM_2:      cp = '/'; break;
            case VK_OEM_3:      cp = '`'; break;
            case VK_OEM_4:      cp = '['; break;
            case VK_OEM_5:      cp = '\\'; break;
            case VK_OEM_6:      cp = ']'; break;
            case VK_OEM_7:      cp = '\''; break;
            case VK_SPACE:      cp = ' '; break;
            default: break;
        }
        if (cp != 0) {
            attyx_handle_key(KC_CODEPOINT, m, et, cp);
            g_suppress_char = 1;
            return 0;
        }
    }

    return 0;
}

// ---------------------------------------------------------------------------
// Keyboard handling — WM_KEYUP
// ---------------------------------------------------------------------------

static LRESULT handleKeyUp(HWND hwnd, WPARAM vk, LPARAM lParam) {
    (void)hwnd;
    if (!(g_kitty_kbd_flags & 2)) {
        if (g_altgr_control_suppressed &&
            winSideSpecificVirtualKey(vk, lParam) == VK_LCONTROL)
            g_altgr_control_suppressed = 0;
        return 0;
    }

    if (routeWinAllKey(vk, lParam, 3)) return 0;

    uint16_t mapped = win_mapVirtualKey(vk, lParam);
    uint8_t m = win_buildMods();
    void (*key_fn)(uint16_t, uint8_t, uint8_t, uint32_t) =
        g_popup_active ? attyx_popup_handle_key : attyx_handle_key;

    if (mapped != UINT16_MAX) {
        key_fn(mapped, m, 3, 0);
    } else if (vk >= 'A' && vk <= 'Z') {
        uint32_t cp = 'a' + (uint32_t)(vk - 'A');
        key_fn(KC_CODEPOINT, m, 3, cp);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Character input — WM_CHAR
// ---------------------------------------------------------------------------

static LRESULT handleChar(HWND hwnd, WPARAM wParam) {
    (void)hwnd;
    if (g_suppress_char > 0) { g_suppress_char--; return 0; }
    if (g_copy_mode) return 0;

    uint32_t codepoint = (uint32_t)wParam;
    if (codepoint < 0x20 && codepoint != '\t' && codepoint != '\r' && codepoint != '\n')
        return 0;

    if (g_search_active) {
        if (codepoint >= 0x20) attyx_search_insert_char(codepoint);
        return 0;
    }
    if (g_ai_prompt_active) {
        if (codepoint >= 0x20) attyx_ai_prompt_insert_char(codepoint);
        return 0;
    }
    if (g_session_picker_active || g_command_palette_active || g_theme_picker_active || g_shell_picker_active) {
        if (codepoint >= 0x20) attyx_picker_insert_char(codepoint);
        return 0;
    }
    if (g_popup_active) {
        attyx_popup_handle_key(KC_CODEPOINT, 0, 1, codepoint);
        return 0;
    }

    win_snapViewport();
    attyx_handle_key(KC_CODEPOINT, 0, 1, codepoint);
    return 0;
}

// ---------------------------------------------------------------------------
// IME handling — minimal framework
// ---------------------------------------------------------------------------

static LRESULT handleImeStartComposition(HWND hwnd) {
    HIMC himc = ImmGetContext(hwnd);
    if (himc) {
        COMPOSITIONFORM cf;
        cf.dwStyle = CFS_POINT;
        float cellW = g_cell_px_w / g_content_scale;
        float cellH = g_cell_px_h / g_content_scale;
        cf.ptCurrentPos.x = (LONG)(g_padding_left + g_cursor_col * cellW);
        cf.ptCurrentPos.y = (LONG)(g_padding_top + g_cursor_row * cellH);
        ImmSetCompositionWindow(himc, &cf);
        ImmReleaseContext(hwnd, himc);
    }
    g_suppress_char = 0;
    g_ime_composing = 1;
    g_ime_anchor_row = g_cursor_row;
    g_ime_anchor_col = g_cursor_col;
    return 0;
}

static LRESULT handleImeComposition(HWND hwnd, LPARAM lParam) {
    HIMC himc = ImmGetContext(hwnd);
    if (!himc) return 0;

    if (lParam & GCS_RESULTSTR) {
        LONG size = ImmGetCompositionStringW(himc, GCS_RESULTSTR, NULL, 0);
        if (size > 0) {
            WCHAR* buf = (WCHAR*)malloc(size + sizeof(WCHAR));
            if (buf) {
                ImmGetCompositionStringW(himc, GCS_RESULTSTR, buf, size);
                buf[size / sizeof(WCHAR)] = 0;
                int utf8_len = WideCharToMultiByte(CP_UTF8, 0, buf, -1, NULL, 0, NULL, NULL);
                if (utf8_len > 0) {
                    char* utf8 = (char*)malloc(utf8_len);
                    if (utf8) {
                        WideCharToMultiByte(CP_UTF8, 0, buf, -1, utf8, utf8_len, NULL, NULL);
                        if (g_kitty_kbd_flags & 8) {
                            dispatchWinKeyExt(KC_CODEPOINT, 0, 1, 0, 0, 0,
                                              (const uint8_t*)utf8,
                                              utf8_len - 1);
                        } else {
                            void (*send_fn)(const uint8_t*, int) =
                                g_popup_active ? attyx_popup_send_input : attyx_send_input;
                            send_fn((const uint8_t*)utf8, utf8_len - 1);
                        }
                        free(utf8);
                    }
                }
                free(buf);
            }
        }
        g_ime_composing = 0;
        g_ime_preedit_len = 0;
    }

    if (lParam & GCS_COMPSTR) {
        LONG size = ImmGetCompositionStringW(himc, GCS_COMPSTR, NULL, 0);
        if (size > 0) {
            WCHAR* buf = (WCHAR*)malloc(size + sizeof(WCHAR));
            if (buf) {
                ImmGetCompositionStringW(himc, GCS_COMPSTR, buf, size);
                buf[size / sizeof(WCHAR)] = 0;
                int utf8_len = WideCharToMultiByte(CP_UTF8, 0, buf, -1, NULL, 0, NULL, NULL);
                if (utf8_len > 0 && utf8_len <= ATTYX_IME_MAX_BYTES) {
                    WideCharToMultiByte(CP_UTF8, 0, buf, -1, g_ime_preedit,
                                        ATTYX_IME_MAX_BYTES, NULL, NULL);
                    g_ime_preedit_len = utf8_len - 1;
                }
                free(buf);
            }
        } else {
            g_ime_preedit_len = 0;
        }
    }

    ImmReleaseContext(hwnd, himc);
    return 0;
}

static LRESULT handleImeEndComposition(HWND hwnd) {
    (void)hwnd;
    g_ime_composing = 0;
    g_ime_preedit_len = 0;
    return 0;
}

// ---------------------------------------------------------------------------
// Main input dispatcher — called from WndProc
// ---------------------------------------------------------------------------

LRESULT windows_handle_input(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case WM_KEYDOWN:
        case WM_SYSKEYDOWN:
            return handleKeyDown(hwnd, wParam, lParam);

        case WM_KEYUP:
        case WM_SYSKEYUP:
            return handleKeyUp(hwnd, wParam, lParam);

        case WM_CHAR:
        case WM_SYSCHAR:
            return handleChar(hwnd, wParam);

        case WM_LBUTTONDOWN:  return win_handleLButtonDown(hwnd, lParam);
        case WM_LBUTTONUP:    return win_handleLButtonUp(hwnd, lParam);
        case WM_RBUTTONDOWN:  return win_handleRButtonDown(hwnd, lParam);
        case WM_RBUTTONUP:    return win_handleRButtonUp(hwnd, lParam);
        case WM_MBUTTONDOWN:  return win_handleMButtonDown(hwnd, lParam);
        case WM_MBUTTONUP:    return win_handleMButtonUp(hwnd, lParam);
        case WM_MOUSEMOVE:    return win_handleMouseMove(hwnd, lParam);
        case WM_MOUSEWHEEL:   return win_handleMouseWheel(hwnd, wParam, lParam);

        case WM_IME_STARTCOMPOSITION: return handleImeStartComposition(hwnd);
        case WM_IME_COMPOSITION:      return handleImeComposition(hwnd, lParam);
        case WM_IME_ENDCOMPOSITION:   return handleImeEndComposition(hwnd);

        default:
            return -1; // Not handled — caller should call DefWindowProc
    }
}

#endif // _WIN32
