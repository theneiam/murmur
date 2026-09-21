#!/usr/bin/env bash
# End-to-end test of the provenance half of scripts/release.sh (MUR-018).
#
# The checks after the build — tree still clean, HEAD unmoved, the record
# written over the finished artifact — only ever run during a real release, so
# they are exactly the code most likely to rot unnoticed. A stub toolchain
# stands in for Xcode, codesign and hdiutil: nothing is compiled or signed, but
# the script itself runs start to finish.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$HERE/lib.sh"
# shellcheck source=scripts/release-gates.sh
. "$ROOT/scripts/release-gates.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/repo"
make_fixture_repo "$STAGE" "$ROOT/scripts"

# --- stub toolchain ----------------------------------------------------------

STUBS="$WORK/bin"
mkdir -p "$STUBS"

cat > "$STUBS/xcodegen" <<'STUB'
#!/bin/sh
[ "$1" = "--version" ] && { echo "Version: 2.46.0"; exit 0; }
exit 0
STUB

# archive: make the archive directory. -exportArchive: write an app bundle with
# a real Info.plist, since release.sh reads the version back with PlistBuddy.
# STUB_MOVE_HEAD / STUB_DIRTY simulate a repository that changes mid-build.
cat > "$STUBS/xcodebuild" <<'STUB'
#!/bin/sh
[ "$1" = "-version" ] && { echo "Xcode 16.0"; echo "Build version 16A242d"; exit 0; }
mode=archive archive="" export_path="" prev=""
for arg in "$@"; do
  case "$prev" in
    -archivePath) archive="$arg" ;;
    -exportPath) export_path="$arg" ;;
  esac
  [ "$arg" = "-exportArchive" ] && mode=export
  prev="$arg"
done
if [ "$mode" = "archive" ]; then
  mkdir -p "$archive/Products"
  exit 0
fi
contents="$export_path/Murmur.app/Contents"
mkdir -p "$contents"
cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>${STUB_APP_VERSION:-2.1.0}</string>
</dict></plist>
PLIST
[ "${STUB_MOVE_HEAD:-0}" = "1" ] && git commit -q --allow-empty -m "moved mid-build"
[ "${STUB_DIRTY:-0}" = "1" ] && printf 'left behind\n' > Leftover.swift
exit 0
STUB

cat > "$STUBS/codesign" <<'STUB'
#!/bin/sh
exit 0
STUB

cat > "$STUBS/security" <<'STUB'
#!/bin/sh
echo '  1) DEADBEEF "Developer ID Application: Test Owner (TESTTEAM00)"'
STUB

# make-dmg.sh's only real work; the last argument is the output path.
cat > "$STUBS/hdiutil" <<'STUB'
#!/bin/sh
for arg in "$@"; do out="$arg"; done
printf 'pretend disk image\n' > "$out"
exit 0
STUB

cat > "$STUBS/swiftformat" <<'STUB'
#!/bin/sh
echo "0.63.0"
STUB

chmod +x "$STUBS"/*
STUB_PATH="$STUBS:$PATH"

RELEASE_DIR="$STAGE/build/release"

run_release() {
  local output status
  output="$(cd "$STAGE" && env PATH="$STUB_PATH" TEAM_ID=TESTTEAM00 SKIP_NOTARIZE=1 "$@" bash scripts/release.sh 2>&1)"
  status=$?
  printf '%s\n' "$output"
  return "$status"
}

# --- a clean release run -----------------------------------------------------

COMMIT="$(release_head_commit "$STAGE")"
OUT="$(run_release)"
assert_equal "a gated release run succeeds" "0" "$?"

assert_success "the DMG exists" test -f "$RELEASE_DIR/Murmur-2.1.0.dmg"
assert_success "provenance was written" test -f "$RELEASE_DIR/$PROVENANCE_FILE"
assert_equal "provenance records the source commit" \
  "$COMMIT" "$(provenance_field "$RELEASE_DIR/$PROVENANCE_FILE" commit)"
assert_equal "provenance records the built version" \
  "2.1.0" "$(provenance_field "$RELEASE_DIR/$PROVENANCE_FILE" version)"
assert_equal "a gated build is marked clean" \
  "clean" "$(provenance_field "$RELEASE_DIR/$PROVENANCE_FILE" state)"
assert_success "the recorded checksums verify" \
  verify_release_provenance "$RELEASE_DIR" "$COMMIT"
assert_output_contains "the run reports the source commit" "source commit: $COMMIT" \
  printf '%s\n' "$OUT"

# The artifact is what the tag will point at.
git -C "$STAGE" tag -a v2.1.0 -m "Fixture 2.1.0"
assert_success "the artifact maps to the tag" \
  require_artifact_matches_tag "$STAGE" v2.1.0 "$RELEASE_DIR"

# --- the bundle's own version is checked -------------------------------------

assert_output_contains "a bundle built at the wrong version fails" \
  "the built app reports version 9.9.9, not 2.1.0" \
  run_release STUB_APP_VERSION=9.9.9

# --- the repository changing mid-build ---------------------------------------

assert_output_contains "a commit during the build is caught" \
  "HEAD moved during the build" run_release STUB_MOVE_HEAD=1
assert_success "no provenance is written for a moved HEAD" \
  test ! -f "$RELEASE_DIR/$PROVENANCE_FILE"
git -C "$STAGE" reset -q --hard v2.1.0

assert_output_contains "a file appearing during the build is caught" \
  "working tree is not clean" run_release STUB_DIRTY=1
assert_success "no provenance is written for a dirty build" \
  test ! -f "$RELEASE_DIR/$PROVENANCE_FILE"
rm -f "$STAGE/Leftover.swift"

# --- a bypassed build is stamped and unpublishable ---------------------------

printf 'uncommitted\n' > "$STAGE/Sneaky.swift"
OUT="$(run_release MURMUR_TEST_BUILD=1)"
assert_equal "a test build still produces an artifact" "0" "$?"
assert_equal "a bypassed build is stamped test-build" \
  "test-build" "$(provenance_field "$RELEASE_DIR/$PROVENANCE_FILE" state)"
assert_failure "a bypassed build is refused at publication" \
  verify_release_provenance "$RELEASE_DIR"
assert_output_contains "the run warns it must not be published" "must not be published" \
  printf '%s\n' "$OUT"
rm -f "$STAGE/Sneaky.swift"

finish
