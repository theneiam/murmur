#!/usr/bin/env bash
# Executable release gates (MUR-018).
#
# docs/RELEASING.md describes clean-source, version and provenance gates that
# used to be prose only: the script finished and a human was trusted to have
# run the checks. Every function here takes explicit arguments and touches no
# globals, so scripts/tests/release-gates.test.sh can exercise each gate
# against throwaway repositories.
#
#   source scripts/release-gates.sh   # from scripts/release.sh and the tests
#   scripts/release-gates.sh preflight [repo]
#   scripts/release-gates.sh verify <provenance-dir> [expected-commit-or-tag]
#
# Bash 3.2 (the macOS system bash) is the target: no associative arrays, no
# ${var,,}, no mapfile.

# --- reporting ---------------------------------------------------------------

gate_pass() { printf '  ✔ %s\n' "$1"; }
gate_warn() { printf '  ! %s\n' "$1" >&2; }
gate_fail() { printf '  ✖ %s\n' "$1" >&2; return 1; }

# --- version arithmetic ------------------------------------------------------

# version_at_least <actual> <minimum> — dotted numeric compare, missing
# components read as 0 ("16" is 16.0.0). Trailing non-digits are ignored so
# "2.46.0-beta" compares as 2.46.0.
version_at_least() {
  local actual="$1" minimum="$2"
  [ -n "$actual" ] || return 1
  local IFS=.
  local a_parts b_parts
  a_parts=($actual)
  b_parts=($minimum)
  unset IFS
  local i x y
  i=0
  while [ "$i" -lt 4 ]; do
    x="${a_parts[$i]:-0}"
    y="${b_parts[$i]:-0}"
    x="${x%%[^0-9]*}"
    y="${y%%[^0-9]*}"
    x="${x:-0}"
    y="${y:-0}"
    if [ "$((10#$x))" -gt "$((10#$y))" ]; then return 0; fi
    if [ "$((10#$x))" -lt "$((10#$y))" ]; then return 1; fi
    i=$((i + 1))
  done
  return 0
}

# --- tool pins ---------------------------------------------------------------

# tool_pin <pins-file> <tool> — minimum version recorded in the pins file.
tool_pin() {
  local file="$1" tool="$2"
  awk -v t="$tool" '!/^[[:space:]]*#/ && $1 == t { print $2; exit }' "$file"
}

# tool_actual_version <tool> — empty when the tool is not installed.
tool_actual_version() {
  case "$1" in
    xcodegen) xcodegen --version 2>/dev/null | sed -n 's/^Version:[[:space:]]*//p' | head -1 ;;
    xcodebuild) xcodebuild -version 2>/dev/null | sed -n 's/^Xcode[[:space:]]*//p' | head -1 ;;
    swiftformat) swiftformat --version 2>/dev/null | head -1 ;;
    git) git --version 2>/dev/null | sed -n 's/^git version \([0-9.]*\).*/\1/p' | head -1 ;;
    *) return 1 ;;
  esac
}

# require_tool_version <tool> <actual> <minimum> — pure, so tests do not need
# a particular Xcode installed.
require_tool_version() {
  local tool="$1" actual="$2" minimum="$3"
  if [ -z "$actual" ]; then
    gate_fail "$tool is not installed (need $minimum or newer)"
    return 1
  fi
  if ! version_at_least "$actual" "$minimum"; then
    gate_fail "$tool $actual is older than the pinned minimum $minimum"
    return 1
  fi
  gate_pass "$tool $actual (>= $minimum)"
}

# require_release_tools <pins-file> — every tool listed in the pins file.
require_release_tools() {
  local file="$1"
  [ -f "$file" ] || { gate_fail "missing tool pins file: $file"; return 1; }
  local status=0 tool minimum actual
  while read -r tool minimum _rest; do
    case "$tool" in "" | \#*) continue ;; esac
    actual="$(tool_actual_version "$tool" || true)"
    require_tool_version "$tool" "$actual" "$minimum" || status=1
  done < "$file"
  return "$status"
}

# --- source cleanliness ------------------------------------------------------

release_dirty_paths() { git -C "$1" status --porcelain; }

release_head_commit() { git -C "$1" rev-parse HEAD; }

# require_clean_tree <repo> — tracked modifications and untracked source both
# fail. Ignored output (Murmur.xcodeproj, build/) never appears in --porcelain.
require_clean_tree() {
  local repo="$1" dirty
  dirty="$(release_dirty_paths "$repo")"
  if [ -n "$dirty" ]; then
    gate_fail "working tree is not clean:"
    printf '%s\n' "$dirty" | sed 's/^/      /' >&2
    return 1
  fi
  gate_pass "working tree is clean"
}

# require_head_commit <repo> <expected> — HEAD did not move mid-build.
require_head_commit() {
  local repo="$1" expected="$2" actual
  actual="$(release_head_commit "$repo")"
  if [ "$actual" != "$expected" ]; then
    gate_fail "HEAD moved during the build: expected $expected, found $actual"
    return 1
  fi
  gate_pass "HEAD still at ${expected:0:7}"
}

# --- version agreement -------------------------------------------------------

project_marketing_version() {
  local file="$1" version
  version="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}[[:space:]]*$/\1/p' "$file" | head -1)"
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

# changelog_latest_version <changelog> — newest dated section, skipping
# [Unreleased].
changelog_latest_version() {
  sed -n 's/^## \[\([0-9][0-9.]*\)\][[:space:]]*-[[:space:]]*[0-9][0-9-]*[[:space:]]*$/\1/p' "$1" | head -1
}

# changelog_release_date <changelog> <version> — empty when the version has no
# dated section yet.
changelog_release_date() {
  local file="$1" escaped
  escaped="$(printf '%s' "$2" | sed 's/\./\\./g')"
  sed -n "s/^## \[$escaped\][[:space:]]*-[[:space:]]*\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)[[:space:]]*\$/\1/p" "$file" | head -1
}

# require_version_agreement <version> <project.yml> <changelog> — the version
# being built is the version the source claims and the changelog documents.
require_version_agreement() {
  local version="$1" project="$2" changelog="$3" marketing date
  marketing="$(project_marketing_version "$project" || true)"
  if [ -z "$marketing" ]; then
    gate_fail "no MARKETING_VERSION found in $project"
    return 1
  fi
  if [ "$version" != "$marketing" ]; then
    gate_fail "version $version does not match MARKETING_VERSION $marketing in $project"
    return 1
  fi
  date="$(changelog_release_date "$changelog" "$version")"
  if [ -z "$date" ]; then
    gate_fail "$changelog has no dated '## [$version] - YYYY-MM-DD' section (still under [Unreleased]?)"
    return 1
  fi
  gate_pass "version $version agrees with $project and is dated $date in the changelog"
}

# require_built_version <built> <expected> — the bundle a user installs is the
# version the gates checked, the changelog describes and the tag will name.
require_built_version() {
  local built="$1" expected="$2"
  if [ "$built" != "$expected" ]; then
    gate_fail "the built app reports version $built, not $expected"
    return 1
  fi
  gate_pass "the built app reports version $built"
}

# --- dependency pins ---------------------------------------------------------

# release_package_pin_problems <project.yml> — prints one line per package that
# is not pinned to an exact version. Package.resolved lives inside the
# git-ignored .xcodeproj, so project.yml is the only pin that survives a fresh
# clone.
release_package_pin_problems() {
  awk '
    /^packages:[[:space:]]*$/ { inpkg = 1; next }
    inpkg && /^[^[:space:]#]/ { inpkg = 0 }
    !inpkg { next }
    /^[[:space:]]*#/ { next }
    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      pkg = $1; sub(/:$/, "", pkg); seen[pkg] = 1; order[++n] = pkg; next
    }
    /^[[:space:]]*exactVersion:/ { if (pkg != "") pinned[pkg] = 1; next }
    /^[[:space:]]*(from|minVersion|maxVersion|branch|revision|majorVersion|minorVersion|upToNextMajorVersion|upToNextMinorVersion):/ {
      if (pkg != "") loose[pkg] = $1
    }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]
        if (!(p in pinned)) printf "%s: no exactVersion pin\n", p
        else if (p in loose) printf "%s: floating rule %s alongside exactVersion\n", p, loose[p]
      }
    }
  ' "$1"
}

require_exact_package_pins() {
  local project="$1" problems
  problems="$(release_package_pin_problems "$project")"
  if [ -n "$problems" ]; then
    gate_fail "package dependencies are not pinned exactly:"
    printf '%s\n' "$problems" | sed 's/^/      /' >&2
    return 1
  fi
  gate_pass "package dependencies are pinned to exact versions"
}

# --- provenance --------------------------------------------------------------

PROVENANCE_FILE="SOURCE_COMMIT.txt"
CHECKSUM_FILE="SHA256SUMS"

# provenance_field <file> <key>
provenance_field() {
  awk -v k="$2" '$1 == k { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }' "$1"
}

# write_release_provenance <dir> <commit> <version> <state> <artifact>...
# state is "clean" for a releasable build or "test-build" for one produced
# with MURMUR_TEST_BUILD=1. verify_release_provenance refuses "test-build",
# which is what keeps the gate from being quietly bypassed at publication.
write_release_provenance() {
  local dir="$1" commit="$2" version="$3" state="$4"
  shift 4
  {
    printf 'commit %s\n' "$commit"
    printf 'version %s\n' "$version"
    printf 'state %s\n' "$state"
    printf 'built %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$dir/$PROVENANCE_FILE"

  local artifact names
  names=""
  for artifact in "$@"; do
    names="$names $(basename "$artifact")"
  done
  (cd "$dir" && shasum -a 256 $names > "$CHECKSUM_FILE")
  gate_pass "wrote $PROVENANCE_FILE and $CHECKSUM_FILE to $dir"
}

# verify_release_provenance <dir> [expected-commit] — run before publishing,
# and again after downloading the published artifact.
verify_release_provenance() {
  local dir="$1" expected="${2:-}" commit state
  [ -f "$dir/$PROVENANCE_FILE" ] || { gate_fail "no $PROVENANCE_FILE in $dir"; return 1; }
  [ -f "$dir/$CHECKSUM_FILE" ] || { gate_fail "no $CHECKSUM_FILE in $dir"; return 1; }

  state="$(provenance_field "$dir/$PROVENANCE_FILE" state)"
  if [ "$state" != "clean" ]; then
    gate_fail "artifact is marked '$state', not publishable (built with gates bypassed)"
    return 1
  fi

  if ! (cd "$dir" && shasum -a 256 -c "$CHECKSUM_FILE" >/dev/null 2>&1); then
    gate_fail "artifact checksums do not match $CHECKSUM_FILE"
    return 1
  fi

  commit="$(provenance_field "$dir/$PROVENANCE_FILE" commit)"
  if [ -n "$expected" ] && [ "$commit" != "$expected" ]; then
    gate_fail "artifact was built from $commit, not $expected"
    return 1
  fi
  gate_pass "artifact checksums match and record commit $commit"
}

# require_artifact_matches_tag <repo> <tag> <provenance-dir> — the published
# tag resolves to the commit the artifact was built from.
require_artifact_matches_tag() {
  local repo="$1" tag="$2" dir="$3" tagged recorded
  tagged="$(git -C "$repo" rev-parse --verify --quiet "$tag^{commit}" || true)"
  if [ -z "$tagged" ]; then
    gate_fail "tag $tag does not exist in $repo"
    return 1
  fi
  recorded="$(provenance_field "$dir/$PROVENANCE_FILE" commit)"
  if [ "$tagged" != "$recorded" ]; then
    gate_fail "tag $tag points at $tagged but the artifact was built from $recorded"
    return 1
  fi
  gate_pass "tag $tag matches the artifact's source commit"
}

# --- CLI ---------------------------------------------------------------------

release_gates_preflight() {
  local repo="${1:-.}" status=0
  echo "▸ Release gates: preflight"
  require_release_tools "$repo/scripts/tool-versions.txt" || status=1
  require_exact_package_pins "$repo/project.yml" || status=1
  require_clean_tree "$repo" || status=1
  require_version_agreement \
    "$(project_marketing_version "$repo/project.yml")" \
    "$repo/project.yml" "$repo/CHANGELOG.md" || status=1
  return "$status"
}

release_gates_main() {
  local command="${1:-}"
  shift || true
  case "$command" in
    preflight) release_gates_preflight "$@" ;;
    verify) verify_release_provenance "$@" ;;
    verify-tag) require_artifact_matches_tag "$@" ;;
    *)
      cat >&2 <<USAGE
usage: scripts/release-gates.sh <command>

  preflight [repo]                       tools, pins, clean tree, version agreement
  verify <dir> [expected-commit]         provenance file and artifact checksums
  verify-tag <repo> <tag> <dir>          tag resolves to the artifact's commit
USAGE
      return 2
      ;;
  esac
}

# Sourced by release.sh and the tests; executed directly as a CLI.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  release_gates_main "$@"
fi
