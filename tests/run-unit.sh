#!/usr/bin/env sh
# Runs every tests/unit/*.bend and compares its output with the file's
# trailing "#|" lines.
set -eu
cd "$(dirname "$0")/.."
export BEND_NO_TELEMETRY=1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
for t in tests/unit/*.bend; do
  sed -n 's/^#|//p' "$t" > "$tmp/want"
  if bend "$t" > "$tmp/got" 2>&1 && cmp -s "$tmp/want" "$tmp/got"; then
    echo "PASS $t"; pass=$((pass + 1))
  else
    echo "FAIL $t"; diff "$tmp/want" "$tmp/got" | head -20 || true; fail=$((fail + 1))
  fi
done
echo "unit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
