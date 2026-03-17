#!/bin/bash
set -euo pipefail

# Clome Dev Build — quick debug build and launch

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_DIR/build/DerivedData"

cd "$PROJECT_DIR"

echo "→ Generating Xcode project..."
xcodegen generate

echo "→ Building Clome (Debug)..."
xcodebuild -project Clome.xcodeproj -scheme Clome \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    build 2>&1 | tail -3

APP_PATH="$DERIVED_DATA/Build/Products/Debug/Clome.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Clome.app not found"
    exit 1
fi

echo "→ Launching Clome..."
open "$APP_PATH"
