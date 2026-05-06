#!/bin/bash
# Inject macOS TCC (Transparency, Consent, Control) usage descriptions
# into the bundled .app's Info.plist + re-sign so the changes stick.
#
# Tauri 2 doesn't support arbitrary Info.plist keys via tauri.conf.json,
# so we patch them in post-build. Without these, macOS silently denies
# Calendar/Reminders Automation access (osascript hangs forever).
#
# Run after `bun run tauri build` or `bun run tauri build --debug`.
#
# Usage:
#   ./scripts/inject-tcc.sh                     # debug build (default)
#   ./scripts/inject-tcc.sh release             # release build

set -euo pipefail

PROFILE="${1:-debug}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$ROOT/src-tauri/target/$PROFILE/bundle/macos/Clome.app"
PLIST="$APP/Contents/Info.plist"

if [ ! -f "$PLIST" ]; then
  echo "✗ Info.plist not found at $PLIST" >&2
  echo "  Did you run \`bun run tauri build\` (or \`--debug\`) first?" >&2
  exit 1
fi

# `plutil -insert` errors if the key already exists; use -replace instead
# so the script is idempotent across re-builds.
plutil -replace NSAppleEventsUsageDescription \
  -string "Clome agents read Mail.app and control Calendar.app or Reminders.app on your behalf when you ask them to." \
  "$PLIST"
plutil -replace NSCalendarsUsageDescription \
  -string "Clome reads your calendar to answer scheduling questions." \
  "$PLIST"
plutil -replace NSRemindersUsageDescription \
  -string "Clome reads and creates reminders on your behalf." \
  "$PLIST"

# Any Info.plist change invalidates the existing ad-hoc signature; macOS
# refuses to launch the app without a re-sign.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
codesign --verify "$APP" >/dev/null 2>&1

echo "✓ TCC strings injected and app re-signed: $APP"
