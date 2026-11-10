#!/usr/bin/env bash
# Hosted-only scope observation. No kernel construction or execution.
set -euo pipefail
export BEND_NO_TELEMETRY=1
export ELAN_TOOLCHAIN=leanprover/lean4:v4.34.0
export ELAN_AUTO_INSTALL=0
export PATH="$HOME/.bend/bin:$HOME/.elan/bin:$PATH"
root=$PWD
logs=$(mktemp -d)
mutant=$(mktemp -d)
trap 'rm -rf "$logs" "$mutant"' EXIT
run_stage() {
  local name=$1 wall=$2 cpu=$3
  shift 3
  local status=0
  local address_kib=3145728
  if [ "$name" = kernel-verdict ]; then
    address_kib=8388608
  fi
  timeout --signal=TERM --kill-after=10s "${wall}s" bash -c '
    set -euo pipefail
    ulimit -t "$1"
    ulimit -v "$2"
    ulimit -f 16384
    shift 2
    exec "$@"
  ' bounded "$cpu" "$address_kib" "$@" >"$logs/$name.out" 2>"$logs/$name.err" || status=$?
  echo 'Export diagnostic stdout/stderr below are tails capped at 8192 bytes each; reasons may be truncated.'
  printf 'STAGE %s EXIT %s\n' "$name" "$status"
  tail -c 8192 "$logs/$name.out"
  tail -c 8192 "$logs/$name.err"
  return "$status"
}
run_stage scope-export 120 120 bend tests/formal/pacing-laws.bend -o "$logs/book.bendtt"
test -s "$logs/book.bendtt"
printf 'EXPORT_BYTES '
wc -c < "$logs/book.bendtt"
sha256sum "$logs/book.bendtt"
grep_status=0
grep -F 'BendTT: out of scope, so not in ' "$logs/scope-export.err" "$logs/scope-export.out" >/dev/null || grep_status=$?
if [ "$grep_status" -eq 0 ]; then
  echo 'OBSERVATION: out-of-scope export diagnostic present; no kernel was requested'
elif [ "$grep_status" -eq 1 ]; then
  echo 'OBSERVATION: no out-of-scope export diagnostic found; not proof or kernel acceptance'
else
  echo "OBSERVATION FAILURE: diagnostic search exit $grep_status" >&2
  exit 1
fi
