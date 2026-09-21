#!/usr/bin/env bash
# Run every shell test. Usage: scripts/tests/run.sh
set -uo pipefail

cd "$(dirname "$0")"
status=0

for test_file in ./*.test.sh; do
  [ -e "$test_file" ] || continue
  printf '\n%s\n' "$(basename "$test_file")"
  bash "$test_file" || status=1
done

if [ "$status" -eq 0 ]; then
  printf '\n✔ shell tests passed\n'
else
  printf '\n✖ shell tests failed\n' >&2
fi
exit "$status"
