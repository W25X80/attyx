# Terminal Basics

A reference for how terminals actually work, written as we learn by building one.

## What Is a Terminal Emulator?

A **terminal** was originally a physical device (like the DEC VT100) — a screen
and keyboard connected to a mainframe via a serial cable. The mainframe sent
bytes down the wire, and the terminal hardware interpreted them.

A **terminal emulator** is software that pretends to be that physical device.
It receives bytes (from a shell process via a PTY), interprets them the same
way, and renders the result on screen.

## The Grid Model

A terminal's display is a fixed-size **grid** of cells, typically 80 columns
by 24 rows. Each cell holds one character (and eventually color/style info).

A **cursor** tracks where the next character will be written, like a typewriter
head. It has a row and column position.

## Control Characters (C0)

Bytes below 0x20 are **control characters** — they don't print anything visible.
Instead they move the cursor or trigger special behavior. These date back to
mechanical teletypes in the 1960s:

| Byte | Abbreviation | Name | What it does |
|------|-------------|------|--------------|
| 0x08 | BS | Backspace | Move cursor left one column (doesn't erase) |
| 0x09 | TAB | Horizontal Tab | Jump to next tab stop (every 8 columns) |
| 0x0A | LF | Line Feed | Move cursor down one row |
| 0x0D | CR | Carriage Return | Move cursor to column 0 |
| 0x1B | ESC | Escape | Start an escape sequence |

### Why LF Doesn't Reset the Column

This surprises many people. In VT terminals, LF ("line feed") literally means
"feed the paper up one line" — it moves the cursor down but does NOT go to
column 0. CR ("carriage return") moves to column 0 but does NOT go down.

That's why network protocols and many file formats use `\r\n` — CR moves to
the start of the line, LF moves to the next line. Two separate operations.

## Escape Sequences

Bytes starting with ESC (0x1B) begin **escape sequences** — multi-byte
instructions that control the terminal beyond what single control characters
can do.

### CSI (Control Sequence Introducer)

The most important family of escape sequences. Format:

```
ESC [ <parameters> <final byte>
```

- **ESC** (0x1B): starts the sequence
- **[** (0x5B): identifies this as a CSI sequence
- **Parameters**: digits and semicolons (0x30–0x3F), e.g., `31;1`
- **Final byte**: a letter (0x40–0x7E) that identifies the command

Examples (not yet implemented in Attyx):

| Sequence | Final | Meaning |
|----------|-------|---------|
| `ESC[H` | H | Move cursor to home (1,1) |
| `ESC[2J` | J | Clear entire screen |
| `ESC[31m` | m | Set text color to red |
| `ESC[A` | A | Move cursor up 1 row |
| `ESC[10;20H` | H | Move cursor to row 10, column 20 |

### Two-byte Escape Sequences

ESC followed by a single byte (not `[`) is a simpler escape sequence:

| Sequence | Meaning |
|----------|---------|
| `ESC D` | Index (move cursor down, scroll if at bottom) |
| `ESC M` | Reverse index (move cursor up, scroll if at top) |
| `ESC 7` | Save cursor position |
| `ESC 8` | Restore cursor position |

These are not yet implemented — currently emitted as Nop by the parser.

## Line Wrapping

When a character is printed at the last column, the cursor wraps to column 0
of the next row. If the cursor is on the bottom row and needs to go further
down, the grid **scrolls**: the top row is discarded, all rows shift up, and
a blank row appears at the bottom.

## The Parser State Machine

Attyx implements a three-state parser:

```
                    ESC
  Ground ──────────────▸ Escape
    ▲                      │
    │  non-[               │  [
    │◂─────────────────────│──────▸ CSI
    │                               │
    │         final byte            │
    │◂──────────────────────────────┘
```

- **Ground**: Normal text processing. Printable bytes print, control bytes
  execute, ESC transitions to Escape.
- **Escape**: Waiting for the byte after ESC. `[` → CSI. Anything else is a
  two-byte escape sequence.
- **CSI**: Buffering parameter bytes until a final byte (0x40–0x7E) terminates
  the sequence.

The parser is **incremental** — it can handle bytes arriving in any chunk size,
even one byte at a time, because it stores its state between calls.
