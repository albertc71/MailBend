#!/usr/bin/env bash
# Hosted diagnostic only; source review must not execute this file.
set -euo pipefail
export BEND_NO_TELEMETRY=1 ELAN_TOOLCHAIN=leanprover/lean4:v4.34.0 ELAN_AUTO_INSTALL=0 DEBUGINFOD_URLS=
test -z "${BENDTT:-}"
test ! -e "$HOME/.bend/bendtt"
test -x /usr/bin/gdb
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
expected=e15042434e73aab07ab05cea4b77b5619082c00a6d4924ea2d4a2cdec05facce
source="$HOME/.bend/bend2/bendtt.lean"
printf '%s  %s\n' "$expected" "$source" | sha256sum -c -
cp "$source" "$work/bendtt.lean"
cmp "$source" "$work/bendtt.lean"
printf 'INFERIOR=not-started\n' > "$work/outcome"
: > "$work/selected"
: > "$work/others"
cat > "$work/commands" <<'GDB'
set pagination off
set confirm off
set auto-load off
set debuginfod enabled off
set disable-randomization off
set startup-with-shell off
set print elements 16
set print max-depth 3
set print frame-arguments none
set backtrace limit 20
python
import gdb
state = {"kind": "not-started"}
def outcome(text):
    with open("outcome", "w") as f:
        f.write(text[:768] + "\n")
def stopped(event):
    state["kind"] = "stopped"
    state["signal"] = getattr(event, "stop_signal", "none")
    outcome("INFERIOR=stopped SIGNAL=" + state["signal"])
def exited(event):
    state["kind"] = "exited"
    outcome("INFERIOR=exited CODE=" + str(getattr(event, "exit_code", "unknown")))
gdb.events.stop.connect(stopped)
gdb.events.exited.connect(exited)
def trace(thread, limit):
    try:
        thread.switch()
        text = "THREAD=" + str(thread.num) + "\n" + gdb.execute("backtrace 20", to_string=True)
    except Exception as error:
        text = "TRACE_ERROR=" + str(error)
    raw = text.encode("utf-8", "replace")
    return raw[:limit] + (b"\nTRUNCATED\n" if len(raw) > limit else b"\n")
try:
    outcome("INFERIOR=launching")
    gdb.execute("run")
    if state["kind"] == "stopped":
        selected = gdb.selected_thread()
        if selected is None:
            raise RuntimeError("no selected stopping thread")
        with open("selected", "wb") as f:
            f.write(trace(selected, 8000))
        others = [t for t in gdb.selected_inferior().threads() if t != selected][:7]
        with open("others", "wb") as f:
            for thread in others:
                f.write(trace(thread, 480))
    elif state["kind"] != "exited":
        outcome("DEBUGGER_ERROR=no stop or exit event")
except Exception as error:
    with open("outcome", "a") as f:
        f.write(("DEBUGGER_ERROR=" + str(error))[:768] + "\n")
gdb.events.stop.disconnect(stopped)
gdb.events.exited.disconnect(exited)
end
quit
GDB
tool="$HOME/.elan/toolchains/leanprover--lean4---v4.34.0/bin/lean"
test -x "$tool"
status=0
timeout --signal=TERM --kill-after=10s 300s bash -c '
  set -euo pipefail
  ulimit -t 240
  ulimit -v 8388608
  ulimit -f 16384
  ulimit -c 0
  cd "$1"
  exec /usr/bin/gdb --batch --nx --nh -iex "set auto-load off" -iex "set debuginfod enabled off" -x commands --args "$2" -j1 -c bendtt.c bendtt.lean
' bounded-diagnostic "$work" "$tool" >"$work/output" 2>&1 || status=$?
case "$status" in
  0) result=debugger-returned ;;
  124) result=wall-timeout ;;
  137) result=killed-timeout-or-other-sigkill ;;
  *) result=debugger-or-setup-failure ;;
esac
printf 'WRAPPER=%s EXIT=%s\n' "$result" "$status"
for pair in outcome:1600 selected:8100 others:3500; do
  file=${pair%:*}
  count=${pair#*:}
  printf '\nSECTION=%s BYTES=' "$file"
  wc -c < "$work/$file"
  head -c "$count" "$work/$file"
done
printf '\nCOMPILER_DEBUGGER_STREAM_BYTES='
wc -c < "$work/output"
echo 'TAIL_MAX=2000; sections clipped at displayed caps; TRACE TRUNCATED marks per-trace clipping'
tail -c 2000 "$work/output"
cmp "$source" "$work/bendtt.lean"
echo 'DIAGNOSTIC_ONLY: debugger return is not compiler success; no generated binary executed'
exit "$status"
