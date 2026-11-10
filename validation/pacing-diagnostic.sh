#!/usr/bin/env bash
# Hosted only. Do not execute in local review.
set -euo pipefail
mode=${1:?capability or compiler}
case "$mode" in capability|compiler) ;; *) exit 2 ;; esac
export BEND_NO_TELEMETRY=1 ELAN_TOOLCHAIN=leanprover/lean4:v4.34.0 ELAN_AUTO_INSTALL=0
export DEBUGINFOD_URLS= LLDB_DEBUGSERVER_PATH=/usr/bin/lldb-server-18
export LLDB_DEBUGSERVER_EXTRA_ARG_1= LLDB_DEBUGSERVER_LOG_FILE= LLDB_SERVER_LOG_CHANNELS=
for tool in /usr/bin/lldb-18 /usr/bin/lldb-server-18; do
  if [ ! -x "$tool" ]; then printf 'CAPABILITY_MISSING=%s\n' "$tool"; exit 1; fi
done
test -z "${BENDTT:-}"
test ! -e "$HOME/.bend/bendtt"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PACING_DIAG_DIR=$work PACING_DIAG_MODE=$mode
export PACING_OBSERVER="$PWD/validation/pacing-observe.py"
export PACING_LEAN="$HOME/.elan/toolchains/leanprover--lean4---v4.34.0/bin/lean"
for file in outcome selected others observer-error cleanup; do : > "$work/$file"; done
printf 'INFERIOR=not-launched\n' > "$work/outcome"
cat > "$work/commands" <<'LLDB'
script import os; exec(compile(open(os.environ['PACING_OBSERVER']).read(), os.environ['PACING_OBSERVER'], 'exec'))
quit
LLDB
wall=20
cpu=10
address=3145728
if [ "$mode" = compiler ]; then
  test -x "$PACING_LEAN"
  expected=e15042434e73aab07ab05cea4b77b5619082c00a6d4924ea2d4a2cdec05facce
  source="$HOME/.bend/bend2/bendtt.lean"
  printf '%s  %s\n' "$expected" "$source" | sha256sum -c -
  cp "$source" "$work/bendtt.lean"
  cmp "$source" "$work/bendtt.lean"
  wall=300
  cpu=240
  address=8388608
fi
status=0
timeout --signal=TERM --kill-after=10s "${wall}s" bash -c '
  set -euo pipefail
  ulimit -t "$1"
  ulimit -v "$2"
  ulimit -f 16384
  ulimit -c 0
  exec /usr/bin/lldb-18 --batch --no-lldbinit --source-before-file "$3"
' bounded-lldb "$cpu" "$address" "$work/commands" >"$work/stream" 2>&1 || status=$?
case "$status" in
  0) result=debugger-returned ;;
  124) result=wall-timeout ;;
  137) result=killed-timeout-or-other-sigkill ;;
  *) result=debugger-or-setup-failure ;;
esac
printf 'WRAPPER=%s EXIT=%s MODE=%s\n' "$result" "$status" "$mode"
if [ "$mode" = capability ]; then
  head -c 1000 "$work/stream"
  test "$status" -eq 0
  test -f "$work/capability"
  grep -Fxq CAPABILITY_OK "$work/capability"
  head -c 512 "$work/capability"
  exit 0
fi
for pair in outcome:1200 observer-error:512 cleanup:256 selected:8100 others:3500; do
  file=${pair%:*}
  count=${pair#*:}
  printf '\nSECTION=%s BYTES=' "$file"
  wc -c < "$work/$file"
  head -c "$count" "$work/$file"
done
printf '\nSTREAM_BYTES='
wc -c < "$work/stream"
echo 'TAIL_MAX=1800; section caps may truncate; per-trace clipping marked TRUNCATED'
tail -c 1800 "$work/stream"
cmp "$source" "$work/bendtt.lean"
echo 'DIAGNOSTIC_ONLY: instrumentation may alter reproduction; no generated binary executed'
test "$status" -eq 0
test -f "$work/finished"
grep -Fxq OBSERVER_FINISHED "$work/finished"
test ! -s "$work/observer-error"
