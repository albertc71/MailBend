#!/usr/bin/env bash
# Hosted-only, one baseline and one semantic mutant. Never run by local review.
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
  printf 'STAGE %s EXIT %s\n' "$name" "$status"
  tail -c 8192 "$logs/$name.out"
  tail -c 8192 "$logs/$name.err"
  return "$status"
}
run_stage parse-affine 120 120 bend src/pacing.bend --check-only
run_stage baseline-laws 120 120 bend tests/formal/pacing-laws.bend --check-only
grep -Fxq 'ALL PROOFS CHECK' "$logs/baseline-laws.out"
test -z "${BENDTT:-}"
test ! -e "$HOME/.bend/bendtt"
run_stage kernel-verdict 300 240 bash -c '
  set -euo pipefail
  root=$1
  identity=$2
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
  sha256sum bendtt > "$identity"
  cd "$root"
  bend tests/formal/pacing-laws.bend --verdict
  cd "$dir"
  sha256sum -c "$identity"
  cmp "$source" bendtt.lean
' fresh-kernel "$root" "$logs/kernel-identity.before"
grep -Fxq 'ALL PROOFS CHECK' "$logs/kernel-verdict.out"
find "$HOME/.bend/bendtt" -type f -name bendtt -exec sha256sum {} \;
run_stage literal-unit 120 120 bend tests/unit/pacing.bend
printf 'wait=1 entries=2\n' > "$logs/expected"
cmp "$logs/expected" "$logs/literal-unit.out"
mkdir -p "$mutant/src" "$mutant/tests/formal" "$mutant/tests/unit"
cp src/pacing.bend "$mutant/src/"
cp tests/formal/pacing-laws.bend "$mutant/tests/formal/"
cp tests/unit/pacing.bend "$mutant/tests/unit/"
python3 - "$mutant/src/pacing.bend" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
old = 'inspect(entries, now, room(budget, cost), 0n, 0n)'
new = 'inspect(prune(entries, now), now, room(budget, cost), 0n, 0n)'
if source.count(old) != 1:
    raise SystemExit('mutation target must occur exactly once')
path.write_text(source.replace(old, new))
PY
cd "$mutant"
run_stage mutant-affine 120 120 bend src/pacing.bend --check-only
# Law rejection and changed runtime output share one unchanged 120-second bound.
run_stage mutant-evidence 120 120 bash -c '
  set -euo pipefail
  logs=$1
  status=0
  bend tests/formal/pacing-laws.bend --check-only >"$logs/mutant-law" 2>&1 || status=$?
  tail -c 8192 "$logs/mutant-law"
  if [ "$status" -eq 0 ] || [ "$status" -ge 124 ]; then
    echo "FAIL: no qualifying semantic rejection"
    exit 1
  fi
  grep -Fq "SOME PROOFS FAIL" "$logs/mutant-law"
  grep -Eq "^Location: ([[:alnum:]_.]+\\.)?mixed_expiry_refusal_keeps_both[[:space:]]*$" "$logs/mutant-law"
  bend tests/unit/pacing.bend >"$logs/mutant-unit" 2>"$logs/mutant-unit.err"
  printf "wait=1 entries=1\n" >"$logs/mutant-expected"
  cmp "$logs/mutant-expected" "$logs/mutant-unit"
  cat "$logs/mutant-unit"
  echo "PASS: named refusal law and independent JavaScript witness detect pruning"
' semantic-mutant "$logs"
cp "$root/src/pacing.bend" src/pacing.bend
cmp "$root/src/pacing.bend" src/pacing.bend
run_stage restored-laws 120 120 bend tests/formal/pacing-laws.bend --check-only
grep -Fxq 'ALL PROOFS CHECK' "$logs/restored-laws.out"
echo 'PASS: restored baseline laws'
