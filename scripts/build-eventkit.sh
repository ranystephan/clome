#!/bin/bash
# Compile the Swift EventKit sidecar to a Tauri-named binary.
#
# Tauri's externalBin resolves sidecars by appending the target triple
# to the configured base name. On Apple Silicon the host triple is
# `aarch64-apple-darwin`. The bundle step copies the matching binary
# into `.app/Contents/MacOS/clome-eventkit` (without the suffix).
#
# Why -O? Release-level optimization — the sidecar runs synchronously
# inside chat turns, debug-Swift startup adds ~150ms we don't need.
#
# Usage:
#   ./scripts/build-eventkit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT/swift/clome-eventkit/main.swift"
OUT_DIR="$ROOT/src-tauri/binaries"

# Detect host triple — must match what Tauri appends to externalBin.
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64)  TRIPLE="aarch64-apple-darwin" ;;
  x86_64) TRIPLE="x86_64-apple-darwin" ;;
  *) echo "✗ unsupported arch: $HOST_ARCH" >&2; exit 1 ;;
esac

OUT="$OUT_DIR/clome-eventkit-$TRIPLE"

mkdir -p "$OUT_DIR"
swiftc -O \
  -framework EventKit -framework Foundation \
  -o "$OUT" \
  "$SRC"

# Ad-hoc sign so macOS treats it as a coherent binary; the bundle's
# subsequent codesign --deep covers it as part of the .app, but signing
# here lets us run it standalone for smoke tests too.
codesign --force --sign - "$OUT" >/dev/null 2>&1

echo "✓ built $OUT"
