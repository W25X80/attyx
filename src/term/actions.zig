/// The set of control codes handled by the terminal.
/// These map directly to the classic C0 control characters
/// that existed on physical teletypes.
pub const ControlCode = enum {
    lf,
    cr,
    bs,
    tab,
};

/// A single terminal action produced by the parser.
///
/// The parser converts raw bytes into Actions; TerminalState
/// consumes Actions and mutates the grid. This separation keeps
/// parsing logic decoupled from state logic.
pub const Action = union(enum) {
    /// Write a printable ASCII byte at the cursor position.
    print: u8,
    /// Execute a C0 control code (LF, CR, BS, TAB).
    control: ControlCode,
    /// No-op: ignored byte or unsupported escape sequence.
    nop,
};
