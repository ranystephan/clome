# Clome (Tauri rewrite) — paths Claude must not confuse

Legacy Swift Clome.app has been removed from this machine. Only the Tauri rewrite remains.

## Tauri rewrite — USE THIS

| Thing | Value |
|-------|-------|
| Display name | **`Clome`** |
| Bundle id | `com.clome.app` |
| Source | `/Users/ranystephan/Desktop/clome_ecosystem/clome/` |
| Dev binary | `/Users/ranystephan/Desktop/clome_ecosystem/clome/src-tauri/target/debug/Clome` |
| Bundled app | `/Applications/Clome.app` |
| App data / DB | `/Users/ranystephan/Library/Application Support/com.clome.app/clome.db/` |
| Run command | `cd /Users/ranystephan/Desktop/clome_ecosystem/clome && bun run tauri dev` |
| Build command | `cd /Users/ranystephan/Desktop/clome_ecosystem/clome && bun run tauri build` |
| Required PATH | `export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"` |

For computer-use `request_access`, pass `"Clome"`.

## Native deps (self-contained)

- `clome/src-tauri/vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a` — static lib linked by `build.rs`.
- `clome/src-tauri/resources/ghostty` — Ghostty runtime resources (passed via `GHOSTTY_RESOURCES_DIR` env at boot).
- `clome/src-tauri/resources/terminfo` — `xterm-ghostty` terminfo entries.

No external repo paths.

## Other paths

- Spec: `/Users/ranystephan/Desktop/clome_ecosystem/REWRITE_SPEC.md`
- Landing site: `/Users/ranystephan/Desktop/clome_ecosystem/clome/site/` (static HTML, no build step)
- Worktree on `clome_ecosystem` repo: this CLAUDE.md lives at `clome/CLAUDE.md` because dev happens in `clome/`. Sibling dirs `clome-brain/`, `clome-ios/`, `clome-relay/` are unrelated legacy projects.
