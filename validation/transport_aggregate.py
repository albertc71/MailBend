"""Bounded complete-runner observations of sticky leak-check evidence."""
import hashlib
import itertools
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

BASE = "1633acf1e5eb5e3829ca0b43596d2a8319f83920"
PRODUCT = "6b0e497ad87c50684f0c3e89e1c54785037892f8"
PRODUCT_TREE = "36c3d9a20dc42d0b369c767239d12ff6560d458d"
BASE_HASH = "68b0e1a30cbbbb7b9b1def0ea9c9663dacc437222f246eb8c37c9c0a38e5a47b"
CANDIDATE_HASH = "40bd444cc075db8f7bdd5a954b0f001ddbbab7f76d7e4390bab3cd37fa392fcc"
SCRIPT = "tests/test-transport.sh"
ADDITIONS = [".github/workflows/transport-aggregate-validation.yml", "validation/transport_aggregate.py"]
ROOT = Path.cwd()
TARGET = ROOT / SCRIPT
DEADLINE = time.monotonic() + 30 * 60
LIMIT = 16 * 1024 * 1024


def require(condition, label):
    if not condition:
        raise RuntimeError(label)


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL, timeout=30)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source_state():
    result = []
    for name in git("ls-files", "-z").split(b"\0"):
        if name:
            path = ROOT / os.fsdecode(name)
            data = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()
            result.append((name, path.lstat().st_mode, digest(data)))
    return result


def admit():
    git("diff", "--no-ext-diff", "--exit-code", "--quiet", "HEAD", "--")
    chain = git("rev-list", "--parents", "-n", "1", "HEAD").decode().split()
    require(len(chain) == 2 and chain[1] == PRODUCT, "validation-parent")
    require(git("rev-list", "--parents", "-n", "1", PRODUCT).decode().split() == [PRODUCT, BASE],
            "product-parent")
    require(git("rev-parse", PRODUCT + "^{tree}").decode().strip() == PRODUCT_TREE, "product-tree")
    require(git("diff", "--name-status", "--no-renames", BASE, PRODUCT, "--") ==
            f"M\t{SCRIPT}\n".encode(), "product-change")
    require(git("diff", "--name-status", "--no-renames", PRODUCT, "HEAD", "--") ==
            "".join(f"A\t{path}\n" for path in ADDITIONS).encode(), "validation-additions")
    for revision in (BASE, PRODUCT, "HEAD"):
        require(git("ls-tree", revision, "--", SCRIPT).startswith(b"100755 blob "), "script-mode")
    candidate = TARGET.read_bytes()
    baseline = git("show", f"{BASE}:{SCRIPT}")
    require(digest(candidate) == CANDIDATE_HASH and digest(baseline) == BASE_HASH, "source-hashes")
    print(f"validation-head={chain[0]} product-head={PRODUCT} product-tree={PRODUCT_TREE}")
    return baseline, candidate


ATTRIBUTION = [f"PASS 18 attribution {protocol} {form} {stream}".encode()
               for protocol, form, stream in itertools.product(
                   ("imap", "smtp"), ("clean", "raw", "login", "plain"), ("stdout", "stderr"))]
ENCODER = [f"PASS 18 encoder failure {i} is distinct and redacted".encode() for i in range(1, 5)]
CASES = [
    ("raw", 1, 1, 1, 0, 0),
    ("clean", 1, 2, 0, 1, 1),
    ("clean", 2, 2, 0, 1, 2),
    ("login", 1, 2, 0, 1, 1),
    ("login", 2, 2, 0, 1, 2),
    ("plain", 1, 2, 0, 1, 1),
    ("plain", 2, 2, 0, 1, 2),
    ("clean", 0, 0, 0, 0, 2),
]
PASS_DIAGNOSTIC = b"PASS 2 password never leaks; LOGIN/AUTH redacted in the log\n"
RAW_DIAGNOSTIC = b"FAIL 2 password never leaks; LOGIN/AUTH redacted in the log -- leak=1 check_error=0 login_redacted=True auth_redacted=True\n"
ERROR_DIAGNOSTIC = b"FAIL 2 password never leaks; LOGIN/AUTH redacted in the log -- leak=0 check_error=1 login_redacted=True auth_redacted=True\n"
ANCHOR = b'        case2\n        [ "$initial_code" -eq 0 ]'
OBSERVER = b'''        case2
        observed_hash=$(sha256sum "$diagnostic")
        printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\\n' "$form" "$stream" "$status" "$initial_code" "$initial_leak" "$initial_error" "$initial_encodes" "$recovered" "$recovered_code" "$recovered_leak" "$recovered_error" "$empty_status" "$CODE" "$GLOBAL_LEAK" "$GLOBAL_LEAK_CHECK_ERROR" "$FAIL_COUNT" "$PASS_COUNT" "$(cat "$counter")" "${observed_hash%% *}" >>"$AGGREGATE_VALIDATION_EVIDENCE"
        [ "$initial_code" -eq 0 ]'''


def expectations(kind):
    labels, records = [], []
    for form, failure, status, leak, error, encodes in CASES:
        for stream in ("stdout", "stderr"):
            initial_status, initial_leak, initial_error, initial_encodes = status, leak, error, encodes
            recovery_error, final_error = error, error
            final_leak = leak
            failed = status != 0
            diagnostic = RAW_DIAGNOSTIC if leak else ERROR_DIAGNOSTIC if error else PASS_DIAGNOSTIC
            rejected = False
            if kind == "old-checker" and status:
                initial_status, initial_leak, initial_error, initial_encodes = 2, 0, 0, failure
                final_leak, recovery_error, final_error, failed = 0, 0, 0, False
                diagnostic, rejected = PASS_DIAGNOSTIC, True
            elif kind in ("omit-login-error", "omit-plain-error") and error and failure == (
                    1 if kind == "omit-login-error" else 2):
                initial_error, recovery_error, final_error, failed = 0, 0, 0, False
                diagnostic, rejected = PASS_DIAGNOSTIC, True
            elif kind == "ignore-error-gate" and error:
                failed = False
                diagnostic, rejected = PASS_DIAGNOSTIC, True
            elif kind == "clear-on-clean" and error:
                recovery_error, final_error, failed = 0, 0, False
                diagnostic, rejected = PASS_DIAGNOSTIC, True
            elif kind == "clear-on-empty" and error:
                final_error, failed = 0, False
                diagnostic, rejected = PASS_DIAGNOSTIC, True
            elif kind == "raw-after-encoding" and form == "raw":
                initial_status, initial_leak, initial_error, initial_encodes = 2, 0, 1, 1
                final_leak, recovery_error, final_error = 0, 1, 1
                diagnostic, rejected = ERROR_DIAGNOSTIC, True
            label = f"leak aggregate {form} {stream} encoder {failure}"
            labels.append(("FAIL " + label + " -- wrong status, sticky evidence, or unsafe diagnostic"
                           if rejected else "PASS " + label).encode())
            values = (form, stream, initial_status, 0, initial_leak, initial_error, initial_encodes,
                      0, 0, final_leak, recovery_error, 0, 0, final_leak, final_error,
                      int(failed), int(not failed), initial_encodes + 2, digest(diagnostic))
            records.append(" ".join(str(value) for value in values) + "\n")
    return labels, "".join(records).encode()


def observe(data, label, kind, passed, failed, work):
    baseline = kind == "baseline"
    require(data.count(ANCHOR) == (0 if baseline else 1), "observer-anchor")
    data = data if baseline else data.replace(ANCHOR, OBSERVER)
    TARGET.write_bytes(data)
    before = source_state()
    capture, evidence = work / label, work / (label + "-evidence")
    evidence.write_bytes(b"")
    seconds = min(600, int(DEADLINE - time.monotonic() - 15))
    require(seconds > 0, "experiment-budget")
    env = {key: os.environ[key] for key in
           ("PATH", "HOME", "CARGO_HOME", "RUSTUP_HOME", "CARGO_BUILD_JOBS") if key in os.environ}
    env.update(LANG="C.UTF-8", LC_ALL="C.UTF-8", PYTHONDONTWRITEBYTECODE="1",
               AGGREGATE_VALIDATION_EVIDENCE=str(evidence))
    with capture.open("wb") as output:
        result = subprocess.run(["timeout", "--signal=TERM", "--kill-after=10s", f"{seconds}s",
                                 "bash", SCRIPT], cwd=ROOT, env=env, stdout=output,
                                stderr=subprocess.STDOUT, check=False, timeout=seconds + 15)
    require(time.monotonic() < DEADLINE, "experiment-budget")
    require(capture.stat().st_size <= LIMIT and evidence.stat().st_size <= 8192, "capture-size")
    output = capture.read_bytes()
    lines = output.splitlines()
    expected_labels, expected_records = ([], b"") if baseline else expectations(kind)
    print(f"{label}: exit={result.returncode} bytes={len(output)} sha256={digest(output)}")
    require(result.returncode == (1 if failed else 0), "runner-status")
    summary = f"transport: {passed} passed, {failed} failed".encode()
    require([line for line in lines if line.startswith(b"transport:")] == [summary], "runner-counts")
    require([line for line in lines if line.startswith(b"FAIL ")] ==
            [line for line in expected_labels if line.startswith(b"FAIL ")], "failure-reason")
    require([line for line in lines if line.startswith((b"PASS leak aggregate ", b"FAIL leak aggregate "))]
            == expected_labels, "aggregate-controls")
    require([line for line in lines if line.startswith((b"PASS 18 attribution ", b"FAIL 18 attribution "))]
            == ATTRIBUTION, "existing-exact-oracle")
    require([line for line in lines if line.startswith((b"PASS 18 encoder failure ", b"FAIL 18 encoder failure "))]
            == ENCODER, "existing-encoder-controls")
    require(lines.count(PASS_DIAGNOSTIC.rstrip(b"\n")) == 1, "suite-aggregate-control")
    require(lines.count(b"PASS password leak checker detects active literal/LOGIN/PLAIN bytes on stdout/stderr") == 1,
            "password-checker-control")
    require(lines[-1] == summary, "runner-completion")
    require(all(marker not in output for marker in (b"canary", b"Y2FuYXJ5", b"AHJlYWRlcgBjYW5hcnk=")),
            "private-marker-in-output")
    require(evidence.read_bytes() == expected_records, "observed-aggregate-reason")
    require(source_state() == before, "runner-source-change")
    print(f"PASS {label}: passed={passed} failed={failed} exact-attribution=16 encoder-controls=4 aggregate-records={0 if baseline else 16}")


def replace_once(data, old, new):
    require(data.count(old) == 1, "mutation-anchor")
    return data.replace(old, new)


def section(data, start, end):
    require(data.count(start) == data.count(end) == 1, "section-boundary")
    return data.split(start)[1].split(end)[0]


def omit_error(candidate, assignment):
    lines = [line for line in candidate.splitlines(keepends=True) if line.startswith(assignment)]
    require(len(lines) == 1 and lines[0].count(b"{ GLOBAL_LEAK_CHECK_ERROR=1; return 2; }") == 1,
            "error-assignment-anchor")
    return replace_once(candidate, lines[0], lines[0].replace(
        b"{ GLOBAL_LEAK_CHECK_ERROR=1; return 2; }", b"return 2"))


def main():
    baseline, candidate = admit()
    if sys.argv[1:] == ["--admit-only"]:
        return
    require(not sys.argv[1:], "arguments")
    before = source_state()
    checker_start = b"check_leak() {\n"
    checker_end = b"\n# Negative controls for the checker itself."
    red = replace_once(candidate, section(candidate, checker_start, checker_end),
                       section(baseline, checker_start, checker_end))
    red = replace_once(red, section(candidate, b"case2() {\n", b"\n# A caller may ignore"),
                       section(baseline, b"case2() {\n", b"\n# Numeric section partials"))
    omit_login = omit_error(candidate, b"  encoded_password=")
    omit_plain = omit_error(candidate, b"  encoded_plain=")
    ignore_gate = replace_once(candidate, b'[ "$GLOBAL_LEAK_CHECK_ERROR" -eq 0 ] && ', b"")
    clear_clean = replace_once(candidate, b"  return 0\n}\n\n# Negative controls",
                               b"  GLOBAL_LEAK_CHECK_ERROR=0\n  return 0\n}\n\n# Negative controls")
    clear_empty = replace_once(candidate, b'[ -n "$password" ] || return 0',
                               b'[ -n "$password" ] || { GLOBAL_LEAK_CHECK_ERROR=0; return 0; }')
    raw = b'''  if grep -aFq -e "$password" -- "$OUT" "$ERR"; then
    GLOBAL_LEAK=1
    return 1
  fi
'''
    raw_late = replace_once(candidate, raw, b"")
    raw_late = replace_once(raw_late, b'grep -aFq -e "$encoded_password" -e "$encoded_plain"',
                            b'grep -aFq -e "$password" -e "$encoded_password" -e "$encoded_plain"')
    try:
        with tempfile.TemporaryDirectory(prefix="transport-aggregate-") as directory:
            work = Path(directory)
            for data, label, kind, passed, failed in [
                    (baseline, "baseline-healthy", "baseline", 247, 0),
                    (red, "new-controls-old-checker", "old-checker", 249, 14),
                    (candidate, "candidate-healthy", "candidate", 263, 0),
                    (omit_login, "mutant-omit-login-error", "omit-login-error", 257, 6),
                    (omit_plain, "mutant-omit-plain-error", "omit-plain-error", 257, 6),
                    (ignore_gate, "mutant-ignore-error-gate", "ignore-error-gate", 251, 12),
                    (clear_clean, "mutant-clear-on-clean", "clear-on-clean", 251, 12),
                    (clear_empty, "mutant-clear-on-empty", "clear-on-empty", 251, 12),
                    (raw_late, "mutant-raw-after-encoding", "raw-after-encoding", 261, 2),
                    (candidate, "candidate-restored", "candidate", 263, 0)]:
                observe(data, label, kind, passed, failed, work)
    finally:
        TARGET.write_bytes(candidate)
        require(source_state() == before, "restored-source-identity")
        git("diff", "--no-ext-diff", "--exit-code", "--quiet", "HEAD", "--")
    print("PASS sticky aggregate sensitivity and restored tracked source identities")


if __name__ == "__main__":
    try:
        main()
    except BaseException as error:
        label = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print("FAIL aggregate validation: " + label)
        raise SystemExit(1)
