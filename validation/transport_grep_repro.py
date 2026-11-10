"""Reproduce ignored grep failures using exact transport checker functions."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

BASE = "846d53e2f5e4540c2761a26817692fb18ec39315"
SOURCE_HASH = "40bd444cc075db8f7bdd5a954b0f001ddbbab7f76d7e4390bab3cd37fa392fcc"
ADDITIONS = [".github/workflows/transport-grep-repro.yml", "validation/transport_grep_repro.py"]
ROOT = Path.cwd()
SCRIPT = "tests/test-transport.sh"
PASS = b"PASS 2 password never leaks; LOGIN/AUTH redacted in the log\n"
LEAK = b"FAIL 2 password never leaks; LOGIN/AUTH redacted in the log -- leak=1 check_error=0 login_redacted=True auth_redacted=True\n"


def require(condition, label):
    if not condition:
        raise RuntimeError(label)


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL, timeout=20)


def section(data, start, end):
    require(data.count(start) == data.count(end) == 1, "function-boundary")
    return start + data.split(start)[1].split(end)[0]


def main():
    chain = git("rev-list", "--parents", "-n", "1", "HEAD").decode().split()
    require(len(chain) == 2 and chain[1] == BASE, "validation-parent")
    require(git("diff", "--name-status", "--no-renames", BASE, "HEAD", "--") ==
            "".join(f"A\t{path}\n" for path in ADDITIONS).encode(), "validation-additions")
    source = (ROOT / SCRIPT).read_bytes()
    require(hashlib.sha256(source).hexdigest() == SOURCE_HASH, "source-hash")
    git("diff", "--exit-code", "--quiet", "HEAD", "--")
    functions = b"\n".join([
        section(source, b"call_helper() {\n", b"\n# call_imap SCRIPT_TEXT"),
        section(source, b"check_leak() {\n", b"\n# Negative controls for the checker itself."),
        section(source, b"case2() {\n", b"\n# A caller may ignore"),
    ])
    preamble = b'''set -u
WORK="$PWD"
CERTDIR="$PWD"
HELPER="$PWD/helper"
PASSWORD=canary
FIXTURE_USER=reader
CASE1_LOG="$PWD/redaction"
CASE12_LOG="$CASE1_LOG"
PASS_COUNT=0; FAIL_COUNT=0; GLOBAL_LEAK=0; GLOBAL_LEAK_CHECK_ERROR=0
pass() { printf 'PASS %s\\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL %s -- %s\\n' "$1" "$2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
'''
    probe = b'''
calls=0
grep() {
  if [ "$1" = -aFq ]; then
    calls=$((calls + 1))
    if [ "$calls" -eq "$FAULT_CALL" ]; then
      printf 'injected\\n' >>"$PWD/injected"
      printf 'canary\\n'
      printf 'canary\\n' >&2
      return "$FAULT_STATUS"
    fi
  fi
  command grep "$@"
}
call_helper smtp '' >first-out 2>first-err
status=$?; initial_code=$CODE
printf '%s %s %s %s\\n' "$status" "$CODE" "$GLOBAL_LEAK" "$GLOBAL_LEAK_CHECK_ERROR" >observed
case2 >first-diagnostic
call_helper smtp '' FORM=clean >later-out 2>later-err
printf '%s %s %s %s\\n' "$?" "$CODE" "$GLOBAL_LEAK" "$GLOBAL_LEAK_CHECK_ERROR" >>observed
call_helper smtp '' MAILBEND_APP_PASSWORD= FORM=clean >empty-out 2>empty-err
printf '%s %s %s %s\\n' "$?" "$CODE" "$GLOBAL_LEAK" "$GLOBAL_LEAK_CHECK_ERROR" >>observed
case2 >last-diagnostic
'''
    helper = b'''#!/bin/sh
case "$FORM" in
  clean) printf 'ordinary reply\\n' ;;
  raw) printf 'canary\\n' ;;
  login) printf 'Y2FuYXJ5\\n' ;;
  plain) printf 'AHJlYWRlcgBjYW5hcnk=\\n' ;;
  *) exit 9 ;;
esac
'''
    print(f"validation-head={chain[0]} source-head={BASE} source-sha256={SOURCE_HASH}")
    cases = [("clean", 0, 0), ("raw", 0, 0), ("login", 0, 0), ("plain", 0, 0)]
    cases += [("clean", call, status) for call in (1, 2) for status in (2, 7)]
    for form, call, status in cases:
        with tempfile.TemporaryDirectory(prefix="transport-grep-repro-") as directory:
            work = Path(directory)
            (work / "helper").write_bytes(helper)
            (work / "helper").chmod(0o700)
            (work / "probe.sh").write_bytes(preamble + functions + probe)
            (work / "redaction").write_bytes(
                b'{"line": "L LOGIN <redacted>"}\n{"line": "AUTH <redacted>"}\n')
            env = {"PATH": os.environ["PATH"], "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
                   "FORM": form, "FAULT_CALL": str(call), "FAULT_STATUS": str(status)}
            result = subprocess.run(["bash", "probe.sh"], cwd=work, env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            require(result.returncode == 0 and result.stdout == result.stderr == b"", "probe-setup")
            leak = int(form != "clean")
            expected = f"{leak} 0 {leak} 0\n0 0 {leak} 0\n0 0 {leak} 0\n".encode()
            require((work / "observed").read_bytes() == expected, "checker-observation")
            for name in ("first-diagnostic", "last-diagnostic"):
                require((work / name).read_bytes() == (LEAK if leak else PASS), "aggregate-observation")
            injected = (work / "injected").read_bytes() if (work / "injected").exists() else b""
            require(injected == (b"injected\n" if call else b""), "fault-reached-once")
            for name in ("first-out", "first-err"):
                require((work / name).read_bytes() == (b"canary\n" if call else b""), "diagnostic-observation")
            for name in ("later-out", "later-err", "empty-out", "empty-err"):
                require((work / name).read_bytes() == b"", "recovered-clean-output")
            print(f"PASS reproduction form={form} grep-call={call} grep-exit={status} "
                  f"checker-status={leak} helper-status=0 leak={leak} checker-error=0 "
                  f"aggregate={'FAIL leak' if leak else 'PASS'}")
    require((ROOT / SCRIPT).read_bytes() == source, "source-restoration")
    print("PASS exact-source reproduction: 4 existing controls, 4 ignored grep errors")


if __name__ == "__main__":
    try:
        main()
    except BaseException as error:
        label = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print("FAIL reproduction: " + label)
        raise SystemExit(1)
