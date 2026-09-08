#ifndef ATTYX_GLFW_CHAR_GATE_H
#define ATTYX_GLFW_CHAR_GATE_H

static inline void attyx_glfw_begin_key(int* suppress_char) {
    *suppress_char = 0;
}

static inline int attyx_glfw_take_suppressed_char(int* suppress_char) {
    int suppressed = *suppress_char != 0;
    *suppress_char = 0;
    return suppressed;
}

#endif
