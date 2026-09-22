#!/usr/bin/env bash
# Tests that scripts/release.sh actually consults the gates (MUR-018).
# release-gates.test.sh covers the gate logic; these cover the wiring — a gate
# that exists but is never called is the failure mode this file exists for.
#
# No Xcode work happens here: every case is expected to stop before, or
# immediately at, `xcodegen generate`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$HERE/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stub toolchain: satisfies the pinned-tool gate, then refuses to generate a
# project. Every case below therefore stops at `xcodegen generate` at the
# latest, and no test ever invokes a real build.
STUBS="$WORK/bin"
mkdir -p "$STUBS"
cat > "$STUBS/xcodegen" <<'STUB'
#!/bin/sh
[ "$1" = "--version" ] && { echo "Version: 2.46.0"; exit 0; }
echo "stub xcodegen: not generating a project in a test" >&2
exit 1
STUB
cat > "$STUBS/swiftformat" <<'STUB'
#!/bin/sh
echo "0.63.0"
STUB
chmod +x "$STUBS/xcodegen" "$STUBS/swiftformat"
STUB_PATH="$STUBS:$PATH"

# A repository shaped like Murmur's, carrying the real scripts.
STAGE="$WORK/repo"
make_fixture_repo "$STAGE" "$ROOT/scripts"

# run_release [env=value]... — prints the script's combined output and exits
# with the script's own status.
run_release() {
  local output status
  output="$(cd "$STAGE" && env PATH="$STUB_PATH" TEAM_ID=TESTTEAM00 SKIP_NOTARIZE=1 "$@" bash scripts/release.sh 2>&1)"
  status=$?
  printf '%s\n' "$output"
  return "$status"
}

# --- a dirty tree stops the release ------------------------------------------

printf 'uncommitted\n' > "$STAGE/Sneaky.swift"

assert_output_contains "a dirty tree fails the release" "working tree is not clean" run_release
assert_output_contains "the dirty file is named" "Sneaky.swift" run_release
assert_output_contains "the failure points at the runbook" "docs/RELEASING.md" run_release

OUT="$(run_release)"
RELEASE_STATUS=$?
assert_equal "a blocked release exits non-zero" "1" "$RELEASE_STATUS"
case "$OUT" in
  *"Generating Xcode project"*) assert_equal "no build starts on a dirty tree" "no build" "a build started" ;;
  *) assert_equal "no build starts on a dirty tree" "no build" "no build" ;;
esac

# --- the documented bypass is loud, and only a bypass -------------------------

# The run continues to the stub xcodegen and dies there, which proves the
# gates were downgraded to warnings rather than skipped.
assert_output_contains "MURMUR_TEST_BUILD keeps going past a dirty tree" \
  "continuing: MURMUR_TEST_BUILD=1" run_release MURMUR_TEST_BUILD=1
assert_output_contains "the bypass still reaches the build" \
  "Generating Xcode project" run_release MURMUR_TEST_BUILD=1
assert_output_contains "the bypass names the stamp the artifact will carry" \
  "test-build" run_release MURMUR_TEST_BUILD=1

rm "$STAGE/Sneaky.swift"

# --- version disagreement stops the release ----------------------------------

assert_output_contains "a version the source does not claim fails" \
  "does not match MARKETING_VERSION" run_release VERSION=9.9.9
OUT="$(run_release VERSION=9.9.9)"
RELEASE_STATUS=$?
assert_equal "a mismatched version exits non-zero" "1" "$RELEASE_STATUS"

# A version still under [Unreleased] is the everyday mistake: project.yml
# bumped, changelog section not dated yet.
sed -i '' 's/MARKETING_VERSION: "2.1.0"/MARKETING_VERSION: "2.2.0"/' "$STAGE/project.yml"
git -C "$STAGE" commit -q -am "bump without a changelog entry"
assert_output_contains "an undocumented version fails" \
  "has no dated" run_release
git -C "$STAGE" revert --no-edit HEAD >/dev/null

# --- a loose dependency stops the release ------------------------------------

sed -i '' 's/exactVersion: "1.1.0"/from: "1.1.0"/' "$STAGE/project.yml"
git -C "$STAGE" commit -q -am "unpin the package"
assert_output_contains "an unpinned dependency fails" \
  "not pinned exactly" run_release
git -C "$STAGE" revert --no-edit HEAD >/dev/null

# --- a clean, agreeing tree reaches the build --------------------------------

assert_output_contains "a clean tree passes the gates" \
  "Generating Xcode project" run_release
assert_output_contains "the clean tree is reported" \
  "working tree is clean" run_release

finish
