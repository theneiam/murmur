#!/usr/bin/env bash
# Build a signed, notarized, stapled Murmur.app and wrap it in a DMG.
#
# Required environment:
#   TEAM_ID            Apple Developer Team ID (10 characters)
#   NOTARY_PROFILE     Name of a notarytool keychain profile, created once with:
#                      xcrun notarytool store-credentials "murmur-notary" \
#                        --apple-id you@example.com --team-id $TEAM_ID --password <app-specific-password>
#
# Optional:
#   VERSION            Overrides MARKETING_VERSION for the build (default: from project.yml)
#   SKIP_NOTARIZE=1    Sign only (useful for local testing)
#
# Usage: TEAM_ID=XXXXXXXXXX NOTARY_PROFILE=murmur-notary scripts/release.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/Murmur.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Murmur.app"

: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID}"
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile name (or SKIP_NOTARIZE=1)}"
fi

echo "▸ Generating Xcode project"
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

rm -rf "$BUILD"
mkdir -p "$BUILD"

EXTRA_SETTINGS=(DEVELOPMENT_TEAM="$TEAM_ID")
if [[ -n "${VERSION:-}" ]]; then
  EXTRA_SETTINGS+=(MARKETING_VERSION="$VERSION")
fi
# Unique build number per release so two 0.1.0 builds never collide.
EXTRA_SETTINGS+=(CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}")

# Pretty output when xcbeautify is installed, raw xcodebuild output otherwise.
if command -v xcbeautify >/dev/null; then PRETTY=(xcbeautify); else PRETTY=(cat); fi

echo "▸ Archiving (Release, arm64)"
xcodebuild archive \
  -project Murmur.xcodeproj \
  -scheme Murmur \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  "${EXTRA_SETTINGS[@]}" \
  2>&1 | "${PRETTY[@]}"

[[ -d "$ARCHIVE" ]] || { echo "Archive failed" >&2; exit 1; }

echo "▸ Exporting with Developer ID signing"
sed "s/TEAM_ID_PLACEHOLDER/$TEAM_ID/" scripts/ExportOptions.plist > "$BUILD/ExportOptions.plist"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$EXPORT" \
  2>&1 | "${PRETTY[@]}"

[[ -d "$APP" ]] || { echo "Export failed" >&2; exit 1; }

echo "▸ Verifying signature"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --entitlements - "$APP" 2>&1 | grep -E "Authority|audio-input|app-sandbox" || true

VERSION_STR="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$BUILD/Murmur-$VERSION_STR.dmg"

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  echo "▸ Notarizing app"
  ditto -c -k --keepParent "$APP" "$BUILD/Murmur.zip"
  xcrun notarytool submit "$BUILD/Murmur.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "▸ Stapling app"
  xcrun stapler staple "$APP"
fi

echo "▸ Building DMG"
scripts/make-dmg.sh "$APP" "$DMG"

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  echo "▸ Notarizing DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "▸ Gatekeeper assessment"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

echo
echo "✔ Done: $DMG"
