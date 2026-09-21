#!/usr/bin/env bash
# Tests for scripts/release-gates.sh (MUR-018). Run via scripts/tests/run.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$HERE/lib.sh"
# shellcheck source=scripts/release-gates.sh
. "$ROOT/scripts/release-gates.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- fixtures ----------------------------------------------------------------

# make_repo <name> — a fixture repository under $WORK, path on stdout.
make_repo() {
  make_fixture_repo "$WORK/$1"
  printf '%s\n' "$WORK/$1"
}

# --- version arithmetic ------------------------------------------------------

assert_success "newer version clears the floor" version_at_least 2.46.0 2.38.0
assert_failure "older version fails the floor" version_at_least 2.38.0 2.46.0
assert_success "equal versions pass" version_at_least 0.52.0 0.52.0
assert_success "missing components read as zero" version_at_least 16 16.0
assert_failure "16.0 does not satisfy 16.1" version_at_least 16.0 16.1
assert_success "prerelease suffix is ignored" version_at_least 2.46.0-beta 2.46.0
assert_failure "an empty version never passes" version_at_least "" 1.0
assert_success "double-digit components compare numerically" version_at_least 26.6 16.0
assert_failure "08 is not greater than 9" version_at_least 1.08.0 1.9.0

# --- tool pins ---------------------------------------------------------------

assert_equal "reads a pin from the real pins file" \
  "2.38.0" "$(tool_pin "$ROOT/scripts/tool-versions.txt" xcodegen)"
assert_equal "comment lines are not pins" \
  "" "$(tool_pin "$ROOT/scripts/tool-versions.txt" '#')"
assert_equal "unknown tools have no pin" \
  "" "$(tool_pin "$ROOT/scripts/tool-versions.txt" cmake)"

assert_failure "a missing tool fails its gate" require_tool_version xcodegen "" 2.38.0
assert_output_contains "a missing tool says so" "is not installed" \
  require_tool_version xcodegen "" 2.38.0
assert_failure "an outdated tool fails its gate" require_tool_version xcodegen 2.10.0 2.38.0
assert_output_contains "an outdated tool names both versions" "older than the pinned minimum" \
  require_tool_version xcodegen 2.10.0 2.38.0
assert_success "an up-to-date tool passes" require_tool_version xcodegen 2.46.0 2.38.0

printf '# tool minimum\ngit 2.30.0\n' > "$WORK/pins-ok.txt"
printf 'definitely-not-a-real-tool 1.0.0\n' > "$WORK/pins-bad.txt"
assert_success "a satisfiable pins file passes" require_release_tools "$WORK/pins-ok.txt"
assert_failure "an unsatisfiable pins file fails" require_release_tools "$WORK/pins-bad.txt"
assert_failure "a missing pins file fails" require_release_tools "$WORK/no-such-pins.txt"

# --- source cleanliness ------------------------------------------------------

REPO="$(make_repo clean)"
assert_success "a committed tree is clean" require_clean_tree "$REPO"

printf 'extra\n' >> "$REPO/CHANGELOG.md"
assert_failure "a modified tracked file is not clean" require_clean_tree "$REPO"
assert_output_contains "the dirty gate names the file" "CHANGELOG.md" require_clean_tree "$REPO"
git -C "$REPO" checkout -- CHANGELOG.md

printf 'draft\n' > "$REPO/NewFeature.swift"
assert_failure "an untracked source file is not clean" require_clean_tree "$REPO"
rm "$REPO/NewFeature.swift"

mkdir -p "$REPO/build" && printf 'x\n' > "$REPO/build/artifact"
assert_success "ignored build output does not break the clean gate" require_clean_tree "$REPO"

HEAD_BEFORE="$(release_head_commit "$REPO")"
assert_success "HEAD unchanged passes" require_head_commit "$REPO" "$HEAD_BEFORE"
git -C "$REPO" commit -q --allow-empty -m "moved"
assert_failure "HEAD moving mid-build fails" require_head_commit "$REPO" "$HEAD_BEFORE"
assert_output_contains "the moved-HEAD gate shows both commits" "HEAD moved during the build" \
  require_head_commit "$REPO" "$HEAD_BEFORE"

# --- version agreement -------------------------------------------------------

assert_equal "reads MARKETING_VERSION from the fixture" \
  "2.1.0" "$(project_marketing_version "$REPO/project.yml")"
assert_equal "reads MARKETING_VERSION from the real project" \
  "1.3.0" "$(project_marketing_version "$ROOT/project.yml")"
assert_equal "newest dated changelog section wins" \
  "2.1.0" "$(changelog_latest_version "$REPO/CHANGELOG.md")"
assert_equal "[Unreleased] is not a version" \
  "1.3.0" "$(changelog_latest_version "$ROOT/CHANGELOG.md")"
assert_equal "finds the release date" \
  "2026-09-16" "$(changelog_release_date "$REPO/CHANGELOG.md" 2.1.0)"
assert_equal "an undocumented version has no date" \
  "" "$(changelog_release_date "$REPO/CHANGELOG.md" 2.2.0)"

assert_success "matching version and dated changelog pass" \
  require_version_agreement 2.1.0 "$REPO/project.yml" "$REPO/CHANGELOG.md"
assert_failure "a version the source does not claim fails" \
  require_version_agreement 2.2.0 "$REPO/project.yml" "$REPO/CHANGELOG.md"
assert_output_contains "the mismatch names MARKETING_VERSION" "does not match MARKETING_VERSION" \
  require_version_agreement 2.2.0 "$REPO/project.yml" "$REPO/CHANGELOG.md"

# A version still sitting under [Unreleased] must not ship.
sed 's/## \[2.1.0\] - 2026-09-16/## [Unreleased]/' "$REPO/CHANGELOG.md" > "$WORK/undated.md"
assert_failure "an undated version fails" \
  require_version_agreement 2.1.0 "$REPO/project.yml" "$WORK/undated.md"
assert_output_contains "the undated gate mentions [Unreleased]" "Unreleased" \
  require_version_agreement 2.1.0 "$REPO/project.yml" "$WORK/undated.md"

printf 'name: NoVersion\n' > "$WORK/no-version.yml"
assert_failure "a project without MARKETING_VERSION fails" \
  require_version_agreement 1.0.0 "$WORK/no-version.yml" "$REPO/CHANGELOG.md"

assert_success "the real project and changelog agree" \
  require_version_agreement "$(project_marketing_version "$ROOT/project.yml")" \
  "$ROOT/project.yml" "$ROOT/CHANGELOG.md"

assert_success "a matching built version passes" require_built_version 2.1.0 2.1.0
assert_failure "a mismatched built version fails" require_built_version 2.1.0 2.2.0
assert_output_contains "the built-version gate names both" "not 2.2.0" \
  require_built_version 2.1.0 2.2.0

# --- dependency pins ---------------------------------------------------------

assert_success "the real project pins its package exactly" \
  require_exact_package_pins "$ROOT/project.yml"
assert_success "the fixture pins its package exactly" \
  require_exact_package_pins "$REPO/project.yml"

cat > "$WORK/floating.yml" <<'YAML'
packages:
  ArgmaxOSS:
    url: https://example.invalid/pkg
    from: "1.1.0"
targets:
  X:
    type: application
YAML
assert_failure "a from: range is not an exact pin" require_exact_package_pins "$WORK/floating.yml"
assert_output_contains "the pin gate names the package" "ArgmaxOSS" \
  require_exact_package_pins "$WORK/floating.yml"

cat > "$WORK/branch.yml" <<'YAML'
packages:
  Tracked:
    url: https://example.invalid/pkg
    branch: main
YAML
assert_failure "a branch dependency is not an exact pin" require_exact_package_pins "$WORK/branch.yml"

cat > "$WORK/both.yml" <<'YAML'
packages:
  Confused:
    url: https://example.invalid/pkg
    exactVersion: "1.0.0"
    upToNextMajorVersion: "1.0.0"
YAML
assert_failure "a floating rule beside exactVersion fails" require_exact_package_pins "$WORK/both.yml"

cat > "$WORK/two.yml" <<'YAML'
packages:
  Pinned:
    url: https://example.invalid/a
    exactVersion: "1.0.0"
  Loose:
    url: https://example.invalid/b
    from: "2.0.0"
targets:
  X:
    type: application
YAML
assert_failure "one loose package among several fails" require_exact_package_pins "$WORK/two.yml"
assert_output_contains "only the loose package is reported" "Loose: no exactVersion pin" \
  require_exact_package_pins "$WORK/two.yml"

printf 'name: NoPackages\ntargets:\n  X:\n    type: application\n' > "$WORK/nopkgs.yml"
assert_success "a project with no packages passes" require_exact_package_pins "$WORK/nopkgs.yml"

# --- provenance --------------------------------------------------------------

OUT="$WORK/release"
mkdir -p "$OUT"
printf 'pretend disk image\n' > "$OUT/Fixture-2.1.0.dmg"
COMMIT="$(release_head_commit "$REPO")"

assert_success "provenance is written" \
  write_release_provenance "$OUT" "$COMMIT" 2.1.0 clean "$OUT/Fixture-2.1.0.dmg"
assert_equal "the commit is recorded" "$COMMIT" "$(provenance_field "$OUT/$PROVENANCE_FILE" commit)"
assert_equal "the version is recorded" "2.1.0" "$(provenance_field "$OUT/$PROVENANCE_FILE" version)"
assert_equal "the state is recorded" "clean" "$(provenance_field "$OUT/$PROVENANCE_FILE" state)"
assert_output_contains "checksums list the artifact by basename" "Fixture-2.1.0.dmg" \
  cat "$OUT/$CHECKSUM_FILE"

assert_success "a clean artifact verifies" verify_release_provenance "$OUT"
assert_success "verifying against the right commit passes" verify_release_provenance "$OUT" "$COMMIT"
assert_failure "verifying against another commit fails" \
  verify_release_provenance "$OUT" 0000000000000000000000000000000000000000
assert_output_contains "the commit mismatch is explained" "was built from" \
  verify_release_provenance "$OUT" 0000000000000000000000000000000000000000

# A tampered or rebuilt artifact must not pass as the one that was measured.
printf 'tampered\n' > "$OUT/Fixture-2.1.0.dmg"
assert_failure "a modified artifact fails its checksum" verify_release_provenance "$OUT"
assert_output_contains "the checksum failure says so" "checksums do not match" \
  verify_release_provenance "$OUT"
printf 'pretend disk image\n' > "$OUT/Fixture-2.1.0.dmg"
assert_success "restoring the artifact restores the match" verify_release_provenance "$OUT"

# The bypass is honest: a test build is stamped and cannot be published.
TESTOUT="$WORK/test-release"
mkdir -p "$TESTOUT"
printf 'pretend disk image\n' > "$TESTOUT/Fixture-2.1.0.dmg"
write_release_provenance "$TESTOUT" "$COMMIT" 2.1.0 test-build "$TESTOUT/Fixture-2.1.0.dmg" >/dev/null
assert_failure "a test build is refused at publication" verify_release_provenance "$TESTOUT"
assert_output_contains "the refusal names the bypass" "gates bypassed" \
  verify_release_provenance "$TESTOUT"

EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
assert_failure "a directory without provenance fails" verify_release_provenance "$EMPTY"
printf 'commit x\nstate clean\n' > "$EMPTY/$PROVENANCE_FILE"
assert_failure "provenance without checksums fails" verify_release_provenance "$EMPTY"

# --- artifact maps to the tag ------------------------------------------------

git -C "$REPO" tag -a v2.1.0 -m "Fixture 2.1.0"
assert_success "the tag matches the artifact's commit" \
  require_artifact_matches_tag "$REPO" v2.1.0 "$OUT"

git -C "$REPO" commit -q --allow-empty -m "after the tag"
git -C "$REPO" tag -a v2.1.1 -m "later"
assert_failure "a tag on a later commit is caught" \
  require_artifact_matches_tag "$REPO" v2.1.1 "$OUT"
assert_output_contains "the tag mismatch shows both commits" "but the artifact was built from" \
  require_artifact_matches_tag "$REPO" v2.1.1 "$OUT"
assert_failure "a missing tag fails" require_artifact_matches_tag "$REPO" v9.9.9 "$OUT"

# --- CLI ---------------------------------------------------------------------

assert_failure "an unknown command prints usage" release_gates_main not-a-command
assert_output_contains "usage mentions preflight" "preflight" release_gates_main not-a-command

finish
