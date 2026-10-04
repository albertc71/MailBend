#!/usr/bin/env sh
# Runs every tests/unit/*.bend and compares its output with the file's
# trailing "#|" lines.
set -eu
cd "$(dirname "$0")/.."
export BEND_NO_TELEMETRY=1
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
expected_output="$temp_dir/expected"
actual_output="$temp_dir/actual"
passed=0
failed=0
for test_file in tests/unit/*.bend; do
  sed -n 's/^#|//p' "$test_file" > "$expected_output"
  if bend "$test_file" > "$actual_output" 2>&1 && cmp -s "$expected_output" "$actual_output"; then
    echo "PASS $test_file"
    passed=$((passed + 1))
  else
    echo "FAIL $test_file"
    diff "$expected_output" "$actual_output" | head -20 || true
    failed=$((failed + 1))
  fi
done
echo "unit: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
