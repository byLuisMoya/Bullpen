# Bullpen

A native macOS app (Apple Silicon and Intel) for running AI coding agents in parallel git worktrees,
with a 2D office per project where every worktree is a character you can watch work.

> Status: early development (phase 0). Nothing usable yet.
> The full plan, in Spanish, is in [docs/PLAN.md](docs/PLAN.md).

## Install

Bullpen is only distributed through [GitHub Releases](https://github.com/byLuisMoya/Bullpen/releases).
It is not notarized by Apple, so the first launch needs one manual step:

1. Download `Bullpen-<version>-universal.zip`, unzip it and move `Bullpen.app` to `/Applications`.
2. Open it. When macOS blocks it, go to System Settings › Privacy & Security and click **Open Anyway**.
   (Or run `xattr -dr com.apple.quarantine /Applications/Bullpen.app`.)

Later versions install themselves through the built-in updater (Sparkle).

## Build

Requires macOS 14+ and Swift 6 (Xcode or Command Line Tools).

```sh
make test   # run the test suite
make app    # build a Universal (arm64 + x86_64) build/Bullpen.app and build/bp
make run    # build and open the app
```

`Scripts/env.sh` applies small workarounds when only the Command Line Tools are installed.

## Layout

| Path | What |
|---|---|
| `Sources/BPCore` | Domain models (projects, worktrees, agent states, office lighting) |
| `Sources/BPPersistence` | SQLite storage (GRDB) |
| `Sources/BullpenApp` | SwiftUI app |
| `Sources/bp` | `bp` command line tool |
| `docs/adr` | Architecture decision records |

## License

Code: [MIT](LICENSE). Character and office art (when it lands): CC BY 4.0.
