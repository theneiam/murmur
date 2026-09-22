#!/usr/bin/env bash
# Minimal assertions for the shell tests. No bats dependency on purpose: the
# release machine and the CI runner both have to run these, and a release gate
# that needs its own install step is a gate that gets skipped.
#
# Deliberately no `set -e` in test files — an assertion runs a command that is
# expected to fail, and an errexit shell would abort on the first one.

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_FILE="$(basename "${BASH_SOURCE[1]:-tests}")"

_run() {
  _out="$("$@" 2>&1)"
  _status=$?
}

_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  ✖ %s\n' "$1"
  shift
  [ $# -gt 0 ] && printf '%s\n' "$@" | sed 's/^/      /'
  return 0
}

_ok() { printf '  ✔ %s\n' "$1"; }

assert_success() {
  local name="$1"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  _run "$@"
  if [ "$_status" -eq 0 ]; then _ok "$name"; else _fail "$name" "expected success, got exit $_status" "$_out"; fi
}

assert_failure() {
  local name="$1"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  _run "$@"
  if [ "$_status" -ne 0 ]; then _ok "$name"; else _fail "$name" "expected failure, got exit 0" "$_out"; fi
}

assert_equal() {
  local name="$1" expected="$2" actual="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then _ok "$name"; else _fail "$name" "expected: '$expected'" "actual:   '$actual'"; fi
}

# assert_output_contains <name> <needle> <cmd>... — the gate has to say why it
# failed, not just return 1.
assert_output_contains() {
  local name="$1" needle="$2"
  shift 2
  TESTS_RUN=$((TESTS_RUN + 1))
  _run "$@"
  case "$_out" in
    *"$needle"*) _ok "$name" ;;
    *) _fail "$name" "expected output to contain: '$needle'" "$_out" ;;
  esac
}

# make_fixture_repo <dir> [scripts-source] — a committed repository shaped like
# Murmur's: a project.yml with an exact package pin, a dated changelog and a
# .gitignore. With a second argument, the real scripts/ is copied in (minus the
# tests) so the release script itself can be run against the fixture.
make_fixture_repo() {
  local dir="$1" scripts_from="${2:-}"
  mkdir -p "$dir"
  cat > "$dir/project.yml" <<'YAML'
name: Fixture
settings:
  base:
    MARKETING_VERSION: "2.1.0"
packages:
  ArgmaxOSS:
    url: https://example.invalid/pkg
    exactVersion: "1.1.0"
targets:
  Fixture:
    type: application
YAML
  cat > "$dir/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

## [2.1.0] - 2026-09-16

### Added
- A thing.

## [2.0.0] - 2026-09-01
MD
  printf 'build/\n*.xcodeproj/\n' > "$dir/.gitignore"
  if [ -n "$scripts_from" ]; then
    cp -R "$scripts_from" "$dir/scripts"
    rm -rf "$dir/scripts/tests"
  fi
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name "Test"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fixture"
}

finish() {
  printf '\n%s: %d assertions, %d failed\n' "$CURRENT_FILE" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ] || exit 1
  exit 0
}
