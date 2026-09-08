#ifndef ATTYX_MACOS_KEY_IDENTITY_H
#define ATTYX_MACOS_KEY_IDENTITY_H

#include <stdint.h>

enum {
    ATTYX_KEY_CODEPOINT = 43,
    ATTYX_KEY_LEFT_SHIFT,
    ATTYX_KEY_LEFT_CONTROL,
    ATTYX_KEY_LEFT_ALT,
    ATTYX_KEY_LEFT_SUPER,
    ATTYX_KEY_RIGHT_SHIFT,
    ATTYX_KEY_RIGHT_CONTROL,
    ATTYX_KEY_RIGHT_ALT,
    ATTYX_KEY_RIGHT_SUPER,
};

static inline uint32_t attyx_macos_standard_codepoint(uint16_t keycode, int shifted) {
    switch (keycode) {
        case 0x00: return shifted ? 'A' : 'a';
        case 0x01: return shifted ? 'S' : 's';
        case 0x02: return shifted ? 'D' : 'd';
        case 0x03: return shifted ? 'F' : 'f';
        case 0x04: return shifted ? 'H' : 'h';
        case 0x05: return shifted ? 'G' : 'g';
        case 0x06: return shifted ? 'Z' : 'z';
        case 0x07: return shifted ? 'X' : 'x';
        case 0x08: return shifted ? 'C' : 'c';
        case 0x09: return shifted ? 'V' : 'v';
        case 0x0B: return shifted ? 'B' : 'b';
        case 0x0C: return shifted ? 'Q' : 'q';
        case 0x0D: return shifted ? 'W' : 'w';
        case 0x0E: return shifted ? 'E' : 'e';
        case 0x0F: return shifted ? 'R' : 'r';
        case 0x10: return shifted ? 'Y' : 'y';
        case 0x11: return shifted ? 'T' : 't';
        case 0x12: return shifted ? '!' : '1';
        case 0x13: return shifted ? '@' : '2';
        case 0x14: return shifted ? '#' : '3';
        case 0x15: return shifted ? '$' : '4';
        case 0x16: return shifted ? '^' : '6';
        case 0x17: return shifted ? '%' : '5';
        case 0x18: return shifted ? '+' : '=';
        case 0x19: return shifted ? '(' : '9';
        case 0x1A: return shifted ? '&' : '7';
        case 0x1B: return shifted ? '_' : '-';
        case 0x1C: return shifted ? '*' : '8';
        case 0x1D: return shifted ? ')' : '0';
        case 0x1E: return shifted ? '}' : ']';
        case 0x1F: return shifted ? 'O' : 'o';
        case 0x20: return shifted ? 'U' : 'u';
        case 0x21: return shifted ? '{' : '[';
        case 0x22: return shifted ? 'I' : 'i';
        case 0x23: return shifted ? 'P' : 'p';
        case 0x25: return shifted ? 'L' : 'l';
        case 0x26: return shifted ? 'J' : 'j';
        case 0x27: return shifted ? '"' : '\'';
        case 0x28: return shifted ? 'K' : 'k';
        case 0x29: return shifted ? ':' : ';';
        case 0x2A: return shifted ? '|' : '\\';
        case 0x2B: return shifted ? '<' : ',';
        case 0x2C: return shifted ? '?' : '/';
        case 0x2D: return shifted ? 'N' : 'n';
        case 0x2E: return shifted ? 'M' : 'm';
        case 0x2F: return shifted ? '>' : '.';
        case 0x31: return ' ';
        case 0x32: return shifted ? '~' : '`';
        default: return 0;
    }
}

static inline uint16_t attyx_macos_modifier_key(uint16_t keycode) {
    switch (keycode) {
        case 0x38: return ATTYX_KEY_LEFT_SHIFT;
        case 0x3B: return ATTYX_KEY_LEFT_CONTROL;
        case 0x3A: return ATTYX_KEY_LEFT_ALT;
        case 0x37: return ATTYX_KEY_LEFT_SUPER;
        case 0x3C: return ATTYX_KEY_RIGHT_SHIFT;
        case 0x3E: return ATTYX_KEY_RIGHT_CONTROL;
        case 0x3D: return ATTYX_KEY_RIGHT_ALT;
        case 0x36: return ATTYX_KEY_RIGHT_SUPER;
        default: return UINT16_MAX;
    }
}

static inline uint32_t attyx_utf16_first_scalar(uint16_t first, uint16_t second, int length) {
    if (length <= 0 || first == 0) return 0;
    if (first >= 0xD800 && first <= 0xDBFF) {
        if (length < 2 || second < 0xDC00 || second > 0xDFFF) return 0;
        return 0x10000u + (((uint32_t)first - 0xD800u) << 10) +
               ((uint32_t)second - 0xDC00u);
    }
    if (first >= 0xDC00 && first <= 0xDFFF) return 0;
    return first;
}

#endif
