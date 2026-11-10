#!/usr/bin/env bash
# Hosted-only direct kernel observation; never a replacement acceptance gate.
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
  if [ "$name" = kernel-observation ]; then
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
  echo 'Stage diagnostic stdout/stderr below are tails capped at 8192 bytes each; reasons may be truncated.'
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
  echo 'STOP: out-of-scope export; kernel will not launch'
  exit 1
elif [ "$grep_status" -eq 1 ]; then
  echo 'OBSERVATION: no out-of-scope export diagnostic found; not proof or kernel acceptance'
else
  echo "OBSERVATION FAILURE: diagnostic search exit $grep_status" >&2
  exit 1
fi
printf '%s  %s\n' bd5587715a99a01a51673894121676b6e60f8ea59b441546baf5ba4627b1b1b1 "$logs/book.bendtt" | sha256sum -c -
run_stage kernel-observation 300 240 bash -c '
  set -euo pipefail
  root=$1
  logs=$2
  test -z "${BENDTT:-}"
  test ! -e "$HOME/.bend/bendtt"
  expected=e15042434e73aab07ab05cea4b77b5619082c00a6d4924ea2d4a2cdec05facce
  source="$HOME/.bend/bend2/bendtt.lean"
  printf "%s  %s\n" "$expected" "$source" | sha256sum -c -
  dir="$HOME/.bend/bendtt/${expected:0:16}"
  tool="$HOME/.elan/toolchains/leanprover--lean4---v4.34.0/bin"
  mkdir -p "$dir"
  cp "$source" "$dir/bendtt.lean"
  cmp "$source" "$dir/bendtt.lean"
  cd "$dir"
  "$tool/lean" -j1 --tstack=262144 -c bendtt.c bendtt.lean
  "$tool/leanc" -O3 -DNDEBUG bendtt.c -o bendtt
  test -x bendtt
  sha256sum bendtt > "$logs/kernel.before"
  cd "$root"
  status=0
  python3 validation/kernel-observe.py "$dir/bendtt" "$logs/book.bendtt" "$logs/kernel.raw" || status=$?
  cd "$dir"
  sha256sum -c "$logs/kernel.before"
  cmp "$source" bendtt.lean
  exit "$status"
' fresh-kernel "$root" "$logs"
