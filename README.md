<div align="center">
  <img src="site/clome-logo.svg" alt="Clome" width="120" />
  <h1>Clome</h1>
  <p><strong>An open-source agentic ecosystem.</strong></p>
  <p>
    <a href="https://github.com/ranystephan/clome/releases/latest"><img src="https://img.shields.io/github/v/release/ranystephan/clome?include_prereleases&label=download&color=000" alt="Download"/></a>
    <img src="https://img.shields.io/badge/license-MIT-000" alt="MIT" />
    <img src="https://img.shields.io/badge/macOS-13%2B-000" alt="macOS 13+" />
    <img src="https://img.shields.io/badge/status-alpha-c4613a" alt="Alpha" />
  </p>
  <p><a href="https://clome.dev">clome.dev</a></p>
</div>

---

Clome is an open-source desktop for building and running local agents. Notes, mail, a knowledge graph, terminal sessions, and chat rooms live in one Tauri/Rust app — and stay on the machine. Each agent has a model, a name, and a short list of explicit capabilities; each capability is a named tool you can read, swap, or remove. The vault is the only context an agent gets, and the vault never leaves your disk. No accounts, no cloud sync, no telemetry. The repo is the spec — clone it, register a tool, write your own agent, ship a PR.

> **Status: alpha.** Source-first, expect breaking changes. macOS only for now.

## Install

Download the latest `.dmg` from the [Releases page](https://github.com/ranystephan/clome/releases/latest) and drag `Clome.app` into `/Applications/`.

The app is **not yet codesigned or notarized**. On first launch macOS will refuse to run it; right-click → Open → Open Anyway, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Clome.app
```

## Build from source

Requirements: macOS 13+, Rust toolchain, [Bun](https://bun.sh), Xcode command-line tools.

```sh
git clone https://github.com/ranystephan/clome
cd clome

# One-time setup: build libghostty.a from source (~5 min on first run)
./scripts/setup-ghostty.sh

# Install JS deps + run the desktop app
bun install
bun run tauri dev

# Or produce a release bundle (.app + .dmg)
bun run tauri build
# → src-tauri/target/release/bundle/macos/Clome.app
# → src-tauri/target/release/bundle/dmg/Clome_<ver>_aarch64.dmg
```

## What's inside

| Layer | Tech |
|------:|------|
| Shell | Tauri 2 |
| Core  | Rust |
| UI    | Solid |
| Store | SQLite |
| Inference | MLX, local |
| Search | BM25 + embeddings (`fastembed`) |
| Terminal | Ghostty (via `libghostty.a`) |
| Mail | IMAP/SMTP, OAuth, locally indexed |
| Calendar / Reminders | macOS EventKit (Swift bridge) |

## Repo layout

```
clome/
├─ src/                    # Solid frontend
├─ src-tauri/              # Rust core (commands, mail, graph, mlx, tools, db)
│  ├─ src/                 # main app
│  ├─ src/bin/             # one-off binaries (seed_vault, ...)
│  ├─ vendor/ghostty/      # libghostty.a is built locally; not committed
│  ├─ resources/           # ghostty runtime resources, terminfo
│  └─ icons/               # app icon set (all platforms)
├─ swift/                  # Swift bridges (EventKit)
├─ scripts/                # setup-ghostty.sh, inject-tcc.sh, seed-vault.js
├─ blueprint/              # design docs for major surfaces
└─ site/                   # landing page (clome.dev), static HTML
```

## Architecture in one breath

The Tauri shell owns the window; the Rust core owns everything else. The **Solid** frontend talks to Rust via Tauri commands — there is no separate backend service. Notes, mail, graph edges, and agent state are persisted in **SQLite**. Search runs locally — **BM25** for lexical, **fastembed** for embeddings. Inference runs locally via **MLX**. Each agent declares a list of *capabilities*; each capability resolves to a small set of named tools the model can call. Tool calls and vault reads surface inline as the turn happens.

## Contributing

The repo is the spec. Fork it, register a tool, write your own agent, send a PR.

## License

[MIT](./LICENSE).
