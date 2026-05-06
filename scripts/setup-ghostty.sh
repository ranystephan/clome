#!/usr/bin/env bash
# Build libghostty.a from Ghostty source and stage it under vendor/.
#
# Required because Ghostty does not ship its xcframework as a
# downloadable release artifact — only the .dmg for the standalone app.
# The xcframework headers are checked into the repo (vendor/.../Headers/),
# but the static library has to be built from source against the same
# tagged version as the bundled headers.
#
# Idempotent: bails out fast if the static lib is already in place.
# Re-run anytime by deleting the lib first.
#
# Requirements:
#   * zig 0.15.x in PATH
#   * git
#   * ~5–15 minutes on first run (Zig dep fetch + build).

set -euo pipefail

GHOSTTY_VERSION="v1.3.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_LIB_DIR="$PROJECT_DIR/src-tauri/vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64"
TARGET_LIB="$VENDOR_LIB_DIR/libghostty.a"
WORK_ROOT="$PROJECT_DIR/src-tauri/vendor/ghostty/build"
SRC_DIR="$WORK_ROOT/source"

# A non-empty static lib is the only signal that we're done. The empty
# stub put down to unblock `cargo check` is treated as "not built".
if [[ -s "$TARGET_LIB" ]]; then
    echo "✓ libghostty.a already in place ($(stat -f%z "$TARGET_LIB") bytes)"
    exit 0
fi

if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig not in PATH (try \`brew install zig\`)" >&2
    exit 1
fi
ZIG_VERSION="$(zig version)"
case "$ZIG_VERSION" in
    0.15.*) ;;
    *) echo "warning: Ghostty $GHOSTTY_VERSION expects zig 0.15.x, found $ZIG_VERSION" >&2 ;;
esac

echo "→ cloning Ghostty $GHOSTTY_VERSION (shallow)"
mkdir -p "$WORK_ROOT"
if [[ ! -d "$SRC_DIR/.git" ]]; then
    git clone --depth 1 --branch "$GHOSTTY_VERSION" \
        https://github.com/ghostty-org/ghostty.git "$SRC_DIR"
else
    echo "  source already present at $SRC_DIR, skipping clone"
fi

pushd "$SRC_DIR" >/dev/null

echo "→ zig build (xcframework, this can take 5–15 min)"
# The xcframework is gated behind `-Demit-xcframework=true` in
# Ghostty 1.3.1's build.zig (see `zig build -h | grep xcframework`).
# `xcframework-target=native` builds for the host arch only — we
# don't need the iOS slices for our Tauri build.
# ReleaseFast matches the upstream macOS app binary.
zig build \
    -Demit-xcframework=true \
    -Dxcframework-target=native \
    -Doptimize=ReleaseFast

# Locate the built static lib. Ghostty 1.3.1 with `xcframework-target=native`
# emits `macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a` (note
# the `-fat` suffix and single-arch dir). The build.rs in this crate
# expects `macos-arm64_x86_64/libghostty.a` — we rename + relocate.
# A `xcframework-target=universal` build would produce the right layout
# directly but pulls x86_64 cross-compile that's overkill for dev.
BUILT_LIB=""
for candidate in \
    "$SRC_DIR/macos/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a" \
    "$SRC_DIR/macos/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty-fat.a" \
    "$SRC_DIR/macos/GhosttyKit.xcframework/macos-arm64/libghostty.a" \
    "$SRC_DIR/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a" \
    "$SRC_DIR/zig-out/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a" \
    "$SRC_DIR/zig-out/lib/libghostty.a"
do
    if [[ -f "$candidate" ]]; then
        BUILT_LIB="$candidate"
        break
    fi
done
if [[ -z "$BUILT_LIB" ]]; then
    BUILT_LIB="$(find "$SRC_DIR" -name 'libghostty*.a' -type f -size +1M 2>/dev/null | head -n 1)"
fi
if [[ -z "$BUILT_LIB" || ! -f "$BUILT_LIB" ]]; then
    echo "error: libghostty.a not found under $SRC_DIR after build" >&2
    exit 1
fi
echo "  located build artifact: $BUILT_LIB"

popd >/dev/null

echo "→ staging libghostty.a → $TARGET_LIB"
mkdir -p "$VENDOR_LIB_DIR"
cp -f "$BUILT_LIB" "$TARGET_LIB"

echo "✓ done. libghostty.a is $(stat -f%z "$TARGET_LIB") bytes"
