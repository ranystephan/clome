# Releasing

Clome is currently released by the maintainer running a local build and uploading the resulting `.dmg` to a GitHub release. CI auto-build is **not used** because:

1. Ghostty 1.3.1's `-Demit-xcframework=true` zig build invokes `xcodebuild` against macOS targets that include `DockTilePlugin`, which requires an Apple developer signing identity GitHub-hosted runners don't have.
2. The resulting `libghostty.a` is ~135 MB — too large for git without LFS.

If those constraints are lifted (vendored prebuilt `libghostty.a`, or a self-hosted macOS runner with signing), the workflow can be re-introduced.

## Manual release

```sh
# 1. Bump version (Cargo.toml + tauri.conf.json + package.json)
# 2. Commit, push
git commit -am "release: v0.X.Y"
git push origin main

# 3. Build the bundle locally
bun install
./scripts/setup-ghostty.sh   # one-time, builds libghostty.a
bun run tauri build
# Bundle lands at:
#   src-tauri/target/release/bundle/dmg/Clome_<ver>_aarch64.dmg
#   src-tauri/target/release/bundle/macos/Clome.app

# 4. Create the release on GitHub (uploads the DMG as an asset)
gh release create v0.X.Y \
  --target main \
  --prerelease \
  --title "Clome v0.X.Y" \
  --notes-file RELEASE_NOTES.md \
  src-tauri/target/release/bundle/dmg/Clome_0.X.Y_aarch64.dmg
```

## Codesigning + notarization

Not yet set up. Users on first launch must allow the app via:

```sh
xattr -dr com.apple.quarantine /Applications/Clome.app
```

To wire up codesigning + notarization:

1. Acquire an Apple Developer ID Application certificate.
2. Set Tauri signing identity in `src-tauri/tauri.conf.json` under `bundle.macOS.signingIdentity`.
3. Set `APPLE_ID`, `APPLE_PASSWORD`, and `APPLE_TEAM_ID` env vars before `bun run tauri build` so `xcrun notarytool` can submit.
