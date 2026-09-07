#!/usr/bin/env bash
# Wrap an .app in a compressed DMG with an /Applications shortcut.
# Usage: scripts/make-dmg.sh path/to/Murmur.app path/to/output.dmg
set -euo pipefail

APP="${1:?path to .app}"
DMG="${2:?output .dmg path}"
NAME="$(basename "$APP" .app)"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "$NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG" >/dev/null

echo "Created $DMG"
