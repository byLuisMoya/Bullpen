# Terminal benchmark — 2026-10-12

- Machine: Mac17,3 · Apple M5 · arm64 · macOS Version 26.6.2 (Build 25G83)
- Corpus: 100 MB of agent-like output (logs, colours, Unicode, TUI redraws), 64 KB chunks
- Parse: emulator only, no drawing. Full frame: synchronous redraw of a 1000×700 pt terminal full of text.
  Stream: corpus fed chunk by chunk while the view redraws on its own schedule (real-world case).
- Terminals for memory/idle: 10, each with 10k lines of scrollback; idle window 10 s

| Engine | Parse (MB/s) | Full frame (ms) | Stream (MB/s) | Stream time (s) | Memory / terminal (MB) | Idle CPU (%) | Notes |
|---|---:|---:|---:|---:|---:|---:|---|
| SwiftTerm (CoreGraphics) | 77.9 | 1.2 | 61.8 | 1.6 | 45.9 | 0.0 | Window occluded (screen locked or asleep?): frame/stream numbers are not reliable |
| SwiftTerm (Metal) | — | — | — | — | — | — | Not built: SwiftTerm >= 1.12 needs full Xcode. This run used SwiftTerm 1.11.2 |
| libghostty | — | — | — | — | — | — | Not built: needs full Xcode + Metal Toolchain + Zig |
