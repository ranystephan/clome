#!/bin/bash
set -euo pipefail

# Clome Release Build Script
# Builds Clome.app and packages it as .dmg and .zip

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKIP_GHOSTTY=false
CONFIGURATION="Release"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --skip-ghostty    Skip building libghostty (use if already built)"
    echo "  --debug           Build Debug configuration instead of Release"
    echo "  --help            Show this help message"
    echo ""
    echo "Output: dist/Clome-{version}-{arch}.dmg and .zip"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-ghostty) SKIP_GHOSTTY=true; shift ;;
        --debug) CONFIGURATION="Debug"; shift ;;
        --help) usage; exit 0 ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; usage; exit 1 ;;
    esac
done

step() { echo -e "\n${BLUE}==>${NC} ${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}Warning:${NC} $1"; }
fail() { echo -e "${RED}Error:${NC} $1"; exit 1; }

VERSION=$(grep 'MARKETING_VERSION' "$PROJECT_DIR/project.yml" | head -1 | sed 's/.*: *"\(.*\)"/\1/')
ARCH=$(uname -m)
DERIVED_DATA="$PROJECT_DIR/build/DerivedData"

echo -e "${GREEN}╔═══════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Clome Release Build v${VERSION}     ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════╝${NC}"
echo ""
echo "  Configuration: $CONFIGURATION"
echo "  Architecture:  $ARCH"

# Step 1: Build libghostty
if [ "$SKIP_GHOSTTY" = true ]; then
    step "Skipping libghostty build (--skip-ghostty)"
    if [ ! -d "$PROJECT_DIR/vendor/ghostty/macos/GhosttyKit.xcframework" ]; then
        fail "libghostty not found. Run without --skip-ghostty first."
    fi
else
    step "Building libghostty..."
    cd "$PROJECT_DIR/vendor/ghostty"
    zig build -Demit-xcframework -Doptimize=ReleaseFast
    cd "$PROJECT_DIR"
    echo -e "  ${GREEN}✓${NC} libghostty built"
fi

# Step 2: Generate Xcode project
step "Generating Xcode project..."
cd "$PROJECT_DIR"
xcodegen generate
echo -e "  ${GREEN}✓${NC} project generated"

# Step 3: Build Clome
step "Building Clome ($CONFIGURATION)..."
xcodebuild -project Clome.xcodeproj -scheme Clome \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    build 2>&1 | tail -5
echo -e "  ${GREEN}✓${NC} build complete"

# Step 4: Find .app
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/Clome.app"
if [ ! -d "$APP_PATH" ]; then
    fail "Clome.app not found at $APP_PATH"
fi
echo -e "  ${GREEN}✓${NC} found $APP_PATH"

# Step 5: Package
step "Packaging..."
DIST_DIR="$PROJECT_DIR/dist"
mkdir -p "$DIST_DIR"

DMG_NAME="Clome-${VERSION}-${ARCH}.dmg"
ZIP_NAME="Clome-${VERSION}-${ARCH}.zip"

# Create DMG
echo "  Creating DMG..."
DMG_STAGING=$(mktemp -d)
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "Clome" -srcfolder "$DMG_STAGING" \
    -ov -format UDZO "$DIST_DIR/$DMG_NAME" -quiet
rm -rf "$DMG_STAGING"
echo -e "  ${GREEN}✓${NC} $DMG_NAME"

# Create ZIP
echo "  Creating ZIP..."
cd "$(dirname "$APP_PATH")"
zip -r -y -q "$DIST_DIR/$ZIP_NAME" Clome.app
cd "$PROJECT_DIR"
echo -e "  ${GREEN}✓${NC} $ZIP_NAME"

# Done
echo ""
echo -e "${GREEN}╔═══════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Build Complete!          ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════╝${NC}"
echo ""
echo "  DMG: dist/$DMG_NAME"
echo "  ZIP: dist/$ZIP_NAME"
echo ""
echo "  To release:"
echo "    git tag v${VERSION}"
echo "    git push origin v${VERSION}"
