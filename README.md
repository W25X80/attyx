<h1 align="center">Attyx</h1>

<p align="center">
  <strong>Deterministic VT-compatible terminal emulator in Zig</strong>
</p>

<p align="center">
  <a href="https://github.com/semos-labs/attyx/actions/workflows/test.yml"><img src="https://github.com/semos-labs/attyx/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <img src="https://img.shields.io/badge/Zig-0.15-f7a41d?logo=zig&logoColor=white" alt="Zig 0.15">
  <img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License">
</p>

<p align="center">
  <a href="#architecture">Architecture</a> &bull;
  <a href="#building">Building</a> &bull;
  <a href="#testing">Testing</a> &bull;
  <a href="#roadmap">Roadmap</a> &bull;
  <a href="docs/">Docs</a>
</p>

---

Attyx is a terminal emulator built from scratch in Zig. The core is a pure, deterministic state machine — no PTY, no windowing, no platform APIs required. Given the same input bytes, it always produces the same grid state.

The project prioritizes **correctness over features** and **clarity over cleverness**. Every feature is testable in headless mode.

---

## Architecture

The core follows a strict pipeline — parsing never touches state, state never influences parsing:

```
Raw bytes ─▸ Parser ─▸ Action ─▸ State.apply() ─▸ Grid
```

| Layer | Directory | Purpose |
|-------|-----------|---------|
| **Terminal engine** | `src/term/` | Pure, deterministic core — parser, state, grid |
| **Headless runner** | `src/headless/` | Test harness and golden snapshot tests |
| **App** | `src/app/` | PTY + OS integration *(planned)* |
| **Renderer** | `src/render/` | GPU + font rendering *(planned)* |

### Key types

- **`Action`** — tagged union (`print`, `control`, `nop`) — the vocabulary between parser and state.
- **`Parser`** — incremental 3-state machine (ground → escape → CSI). Zero allocations, handles partial sequences across chunk boundaries.
- **`TerminalState`** — grid + cursor. Mutates only via `apply(action)`.
- **`Engine`** — glue that connects parser and state with a simple `feed(bytes)` API.

See [docs/architecture.md](docs/architecture.md) for the full breakdown.

---

## Building

Requires **Zig 0.15.2+**.

```bash
zig build          # build the executable
zig build run      # build and run
```

---

## Testing

All tests run in headless mode — no PTY, no window, no OS interaction.

```bash
zig build test                # run all tests
zig build test --summary all  # run with detailed summary
```

The test suite uses **golden snapshot testing**: feed known bytes into a terminal of known size, serialize the grid to a plain-text string, and compare against an exact expected value.

| What's tested | Count |
|---------------|-------|
| Grid operations (get/set, scroll, clear) | 4 |
| Parser state machine (ESC, CSI, transitions) | 10 |
| State mutations (apply each action type) | 6 |
| Snapshot serialization | 2 |
| Engine + runner integration | 3 |
| Golden behavior tests (printing, wrapping, CR/LF, TAB, BS, scrolling, ESC/CSI) | 23 |
| **Total** | **48** |

See [docs/testing.md](docs/testing.md) for the full testing strategy.

---

## Roadmap

Attyx is built milestone by milestone. Each milestone is stable and tested before the next begins.

| # | Milestone | Status |
|---|-----------|--------|
| 1 | Grid + cursor + printable text + control chars | ✅ Done |
| 2 | Action stream + parser skeleton (ESC/CSI framing) | ✅ Done |
| 3 | Minimal CSI support (cursor movement, erase, SGR 16 colors) | 🔜 Next |
| 4 | Scroll + scrollback buffer | Planned |
| 5 | Alternate screen (`?1049h` / `?1049l`) | Planned |
| 6 | Damage tracking (dirty rows) | Planned |
| 7 | PTY integration | Planned |
| 8 | GPU rendering | Planned |

See [docs/milestones.md](docs/milestones.md) for detailed write-ups.

---

## Project Structure

```
src/
  term/
    actions.zig      Action union + ControlCode enum
    parser.zig       Incremental VT parser (ground/escape/CSI)
    state.zig        TerminalState — grid + cursor + apply()
    grid.zig         Cell + Grid — 2D character storage
    snapshot.zig     Grid → plain text serialization
    engine.zig       Glue: Parser + TerminalState
  headless/
    runner.zig       Test convenience functions
    tests.zig        Golden snapshot tests
  root.zig           Library root
  main.zig           Executable entry point
docs/
  architecture.md    System design and data flow
  milestones.md      Milestone details and history
  terminal-basics.md How terminals work (learning reference)
  testing.md         Test strategy and snapshot format
```

---

## License

MIT

---

<p align="center">
  <sub>Built byte by byte &bull; escape sequence by escape sequence</sub>
</p>
