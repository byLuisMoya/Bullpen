<img src="Resources/AppIcon.png" width="128" alt="Bullpen icon">

# Bullpen

A native macOS app (Apple Silicon and Intel) for running AI coding agents in parallel git worktrees,
with a 2D office per project where every worktree is a character you can watch work.

> Status: early development (phases 0–4 of [the plan](docs/PLAN.md) done); expect rough edges.

![The building: one office per project, one person per worktree](docs/images/building-preview.png)
> The full plan, in Spanish, is in [docs/PLAN.md](docs/PLAN.md).

## What it does

- **Worktrees per task**, each with its own terminal that keeps running when the app is closed.
- **Agents**: Claude Code, Codex, Gemini CLI, OpenCode, Cursor, Copilot, Aider, Goose, Amp or your own
  ([docs/agents.md](docs/agents.md)), with a per-project initial prompt.
- **Live state** (working, needs you, done…) from the agents' hooks, with notifications and a soft sound of your choice for each.
- **The building**: one pixel-art office per project, one person per worktree.
- **Branch and PR state** like Orca; warnings when worktrees overlap or would conflict.
- **Review**: diff with line comments sent to the agent, file viewer, the agent's log, PR creation.
- **`.bullpen.toml`**: setup, per-worktree ports and env, teardown and verify ([docs/bullpen-toml.md](docs/bullpen-toml.md)).
- **Compare agents** on the same task, with an optional judge model.
- **Tickets**: start from GitHub issues or Linear; usage and cost estimates; limits.
- **`bp` CLI and `bp mcp`** so agents can drive Bullpen too, and coordinate: a mailbox that never interrupts, and a shared task board per project.

Try it without spending tokens: `make demo` (and `make demo-stop` to remove it).

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
| `Sources/BPGit` | git CLI wrapper: repositories and worktrees |
| `Sources/BPSessions` | PTY sessions, `bpd` protocol, server and client |
| `Sources/bpd` | Session daemon: keeps terminals and agents alive when the app closes |
| `Sources/BullpenApp` | SwiftUI app |
| `Sources/BPAgents` | Agent profiles, hooks, initial prompts, status engine |
| `Sources/BPHabitat` | The building: pixel-art offices and characters (Core Animation) |
| `Sources/bp` | `bp` command line tool (`bp sessions`, `bp agent`, `bp hook`) |
| `docs/adr` | Architecture decision records |

## License

Code: [MIT](LICENSE). Character and office art (when it lands): CC BY 4.0.
