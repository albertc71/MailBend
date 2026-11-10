"""Verify complete transport runs, selected grep faults, and rejected mutations."""
import hashlib
import itertools
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

BASE = "846d53e2f5e4540c2761a26817692fb18ec39315"
TESTS = "c101bb86c3cee8858e5d377b909d248fbc20b7bf"
PRODUCT = "9133ed5d8a20a56a6511a647e0f5c3cfff2e45ad"
PRODUCT_TREE = "b02426d5a874d0b01cbf67748485ae80713aa284"
BASE_HASH = "40bd444cc075db8f7bdd5a954b0f001ddbbab7f76d7e4390bab3cd37fa392fcc"
TEST_HASH = "0988e1a869d1c98dfe1d157f910f59c98a1ed431437516e567ec5ff1f59777bd"
CANDIDATE_HASH = "c60aeed8a6cb04d5f7a20d183777635c8ce9779d1d6b4f216f18afe7607910d2"
SCRIPT = "tests/test-transport.sh"
ADDITIONS = [".github/workflows/transport-grep-validation.yml", "validation/transport_grep.py"]
ROOT = Path.cwd()
TARGET = ROOT / SCRIPT
DEADLINE = time.monotonic() + 38 * 60
PASS_AGGREGATE = b"PASS 2 password never leaks; LOGIN/AUTH redacted in the log"
FAIL_AGGREGATE = b"FAIL 2 password never leaks; LOGIN/AUTH redacted in the log -- leak=0 check_error=1 login_redacted=True auth_redacted=True"
GREP_CASES = [(0, "0"), (1, "2"), (1, "7"), (2, "2"), (2, "7"), (1, "missing"), (2, "missing")]
GREP_LABELS = [f"leak grep phase {phase} failure {status}".encode() for phase, status in GREP_CASES]
GREP_DETAIL = b" -- wrong status, sticky evidence, or unsafe diagnostic"
AGGREGATE_ERRORS = [f"leak aggregate {form} {stream} encoder {failure}".encode()
                    for form, failure, stream in itertools.product(
                        ("clean", "login", "plain"), (1, 2), ("stdout", "stderr"))]


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
    git("diff", "--exit-code", "--quiet", "HEAD", "--")
    head = git("rev-parse", "HEAD").decode().strip()
    for child, parent in ((head, PRODUCT), (PRODUCT, TESTS), (TESTS, BASE)):
        require(git("rev-list", "--parents", "-n", "1", child).decode().split() == [child, parent],
                "single-parent-history")
    require(git("rev-parse", PRODUCT + "^{tree}").decode().strip() == PRODUCT_TREE, "product-tree")
    for first, last in ((BASE, TESTS), (TESTS, PRODUCT)):
        require(git("diff", "--name-status", "--no-renames", first, last, "--") ==
                f"M\t{SCRIPT}\n".encode(), "product-scope")
    require(git("diff", "--name-status", "--no-renames", PRODUCT, head, "--") ==
            "".join(f"A\t{path}\n" for path in ADDITIONS).encode(), "validation-additions")
    sources = []
    for revision, expected in ((BASE, BASE_HASH), (TESTS, TEST_HASH), (PRODUCT, CANDIDATE_HASH)):
        require(git("ls-tree", revision, "--", SCRIPT).startswith(b"100755 blob "), "source-mode")
        source = git("show", revision + ":" + SCRIPT)
        require(digest(source) == expected, "source-hash")
        sources.append(source)
    require(TARGET.read_bytes() == sources[2], "checkout-source")
    print(f"validation-head={head} product-head={PRODUCT} product-tree={PRODUCT_TREE}", flush=True)
    return sources


def replace_once(data, old, new):
    require(data.count(old) == 1, "mutation-anchor")
    return data.replace(old, new)


def injected(data):
    before = b'''validation_grep_calls=0
grep() {
  if [ "$1" = -aFq ]; then
    validation_grep_calls=$((validation_grep_calls + 1))
    if [ "$validation_grep_calls" -eq "$VALIDATION_GREP_PHASE" ]; then
      printf 'injected %s %s\\n' "$VALIDATION_GREP_PHASE" "$VALIDATION_GREP_STATUS" >>"$VALIDATION_GREP_EVIDENCE"
      return "$VALIDATION_GREP_STATUS"
    fi
  fi
  command grep "$@"
}
'''
    return replace_once(data, b"\ncase1\ncase3\n", b"\n" + before + b"case1\nunset -f grep\ncase3\n")


def expected_lines(baseline, new_controls, rejected, aggregate_error):
    lines = list(baseline)
    if new_controls:
        anchor = b"PASS password leak checker detects active literal/LOGIN/PLAIN bytes on stdout/stderr"
        require(lines.count(anchor) == 1, "baseline-control-anchor")
        at = lines.index(anchor)
        lines[at:at] = [b"PASS " + label for label in GREP_LABELS]
    for label in rejected:
        old = b"PASS " + label
        require(lines.count(old) == 1, "expected-failure-label")
        lines[lines.index(old)] = b"FAIL " + label + GREP_DETAIL
    if aggregate_error:
        require(lines.count(PASS_AGGREGATE) == 1, "aggregate-anchor")
        lines[lines.index(PASS_AGGREGATE)] = FAIL_AGGREGATE
    return lines


def instrument_controls(data):
    start = b"case_leak_grep_controls() {\n"
    end = b"# Numeric section partials retain literal framing and the UIDVALIDITY guard."
    require(data.count(start) == data.count(end) == 1, "control-boundaries")
    prefix, rest = data.split(start)
    body, suffix = rest.split(end)
    body = replace_once(body, b"      status=$?; initial_error=$GLOBAL_LEAK_CHECK_ERROR\n",
                        b'''      status=$?; initial_error=$GLOBAL_LEAK_CHECK_ERROR
      printf 'initial %s %s %s %s %s %s %s\\n' "$phase" "$failure" "$status" "$CODE" "$GLOBAL_LEAK" "$initial_error" "$faults" >>"$VALIDATION_GREP_RECORDS"
''')
    body = replace_once(body, b"      recovered=$?\n", b'''      recovered=$?
      printf 'recovered %s %s %s %s %s\\n' "$phase" "$failure" "$recovered" "$CODE" "$GLOBAL_LEAK_CHECK_ERROR" >>"$VALIDATION_GREP_RECORDS"
''')
    body = replace_once(body, b"      case2\n", b'''      case2
      printf 'final %s %s %s %s %s %s %s %s\\n' "$phase" "$failure" "$empty_status" "$CODE" "$GLOBAL_LEAK" "$GLOBAL_LEAK_CHECK_ERROR" "$FAIL_COUNT" "$PASS_COUNT" >>"$VALIDATION_GREP_RECORDS"
''')
    body = replace_once(body, b"    result=$?\n", b'''    result=$?
    if [ "$failure" != missing ]; then
      observed_hash=$(sha256sum "$diagnostic")
      printf 'diagnostic %s %s %s\\n' "$phase" "$failure" "${observed_hash%% *}" >>"$VALIDATION_GREP_RECORDS"
    fi
''')
    return prefix + start + body + end + suffix


def expected_records(kind):
    records = []
    for phase, failure in GREP_CASES:
        failed = int(phase != 0)
        status, error, recovered_error, final_error = 2 * failed, failed, failed, failed
        if kind == "new-controls-old-checker" and failed:
            status, error, recovered_error, final_error = 0, 0, 0, 0
        if (kind == "omit-raw-sticky" and phase == 1) or (kind == "omit-encoded-sticky" and phase == 2):
            error, recovered_error, final_error = 0, 0, 0
        if kind == "clear-on-clean":
            recovered_error, final_error = 0, 0
        if kind == "clear-on-empty":
            final_error = 0
        records.append(f"initial {phase} {failure} {status} 0 0 {error} {failed}\n")
        records.append(f"recovered {phase} {failure} 0 0 {recovered_error}\n")
        diagnostic = b""
        if recovered_error == failed:
            aggregate_failed = int(bool(final_error) and kind != "ignore-aggregate-error")
            records.append(f"final {phase} {failure} 0 0 0 {final_error} {aggregate_failed} {1 - aggregate_failed}\n")
            diagnostic = (FAIL_AGGREGATE if aggregate_failed else PASS_AGGREGATE) + b"\n"
        if kind in ("new-controls-old-checker", "leaky-grep-diagnostics") and failed and failure != "missing":
            diagnostic = b"canary\ncanary\n" + diagnostic
        if failure != "missing":
            records.append(f"diagnostic {phase} {failure} {digest(diagnostic)}\n")
    return "".join(records).encode()


def observe(data, label, work, baseline=None, total=None, new_controls=True,
            rejected=(), phase=0, status=0, aggregate_error=False):
    observed = instrument_controls(data) if new_controls else data
    TARGET.write_bytes(injected(observed) if phase else observed)
    before = source_state()
    capture, evidence, records = work / label, work / (label + "-evidence"), work / (label + "-records")
    evidence.write_bytes(b"")
    records.write_bytes(b"")
    seconds = min(600, int(DEADLINE - time.monotonic() - 15))
    require(seconds > 0, "experiment-budget")
    env = {key: os.environ[key] for key in
           ("PATH", "HOME", "CARGO_HOME", "RUSTUP_HOME", "CARGO_BUILD_JOBS") if key in os.environ}
    env.update(LANG="C.UTF-8", LC_ALL="C.UTF-8", PYTHONDONTWRITEBYTECODE="1",
               VALIDATION_GREP_PHASE=str(phase), VALIDATION_GREP_STATUS=str(status),
               VALIDATION_GREP_EVIDENCE=str(evidence), VALIDATION_GREP_RECORDS=str(records))
    with capture.open("wb") as output:
        result = subprocess.run(["timeout", "--signal=TERM", "--kill-after=10s", f"{seconds}s",
                                 "bash", SCRIPT], cwd=ROOT, env=env, stdout=output,
                                stderr=subprocess.STDOUT, check=False, timeout=seconds + 15)
    require(time.monotonic() < DEADLINE and capture.stat().st_size <= 16 * 1024 * 1024,
            "experiment-budget-or-size")
    output = capture.read_bytes()
    decisions = [line for line in output.splitlines() if line.startswith((b"PASS ", b"FAIL "))]
    summaries = re.findall(rb"^transport: ([0-9]+) passed, ([0-9]+) failed$", output, re.MULTILINE)
    require(len(summaries) == 1, "runner-summary")
    passed, failed = map(int, summaries[0])
    print(f"{label}: exit={result.returncode} passed={passed} failed={failed} bytes={len(output)} sha256={digest(output)}",
          flush=True)
    require(output.splitlines()[-1] == f"transport: {passed} passed, {failed} failed".encode(),
            "runner-completion")
    if baseline is None:
        require(result.returncode == failed == 0 and passed > 0, "healthy-baseline")
        require(all(line.startswith(b"PASS ") for line in decisions), "baseline-failures")
        require(decisions.count(PASS_AGGREGATE) == 1, "baseline-aggregate")
        require(decisions.count(b"PASS 1 IMAP happy path") == 1, "baseline-real-case")
    else:
        expected_failed = len(rejected) + int(aggregate_error)
        expected_passed = total + (len(GREP_LABELS) if new_controls else 0) - expected_failed
        require((passed, failed) == (expected_passed, expected_failed), "runner-counts")
        require(result.returncode == (1 if failed else 0), "runner-status")
        require(decisions == expected_lines(baseline, new_controls, rejected, aggregate_error),
                "exact-runner-decisions")
    for protocol, form, stream in itertools.product(
            ("imap", "smtp"), ("clean", "raw", "login", "plain"), ("stdout", "stderr")):
        require(decisions.count(f"PASS 18 attribution {protocol} {form} {stream}".encode()) == 1,
                "preserved-raw-and-encoded-controls")
    for index in range(1, 5):
        require(decisions.count(f"PASS 18 encoder failure {index} is distinct and redacted".encode()) == 1,
                "preserved-encoder-controls")
    require(all(marker not in output for marker in (b"canary", b"Y2FuYXJ5", b"AHJlYWRlcgBjYW5hcnk=")),
            "synthetic-secret-in-output")
    require(evidence.read_bytes() == (f"injected {phase} {status}\n".encode() if phase else b""),
            "outside-sentinel-injection")
    require(records.read_bytes() == (expected_records(label) if new_controls else b""),
            "observed-checker-status-flags-and-diagnostics")
    require(source_state() == before, "runner-source-change")
    if aggregate_error:
        print(FAIL_AGGREGATE.decode(), flush=True)
    print(f"PASS {label}: exact decisions, preserved controls, reached final aggregate, semantic records verified", flush=True)
    return decisions, passed


def main():
    original, tests, candidate = admit()
    if sys.argv[1:] == ["--admit-only"]:
        return
    require(not sys.argv[1:], "arguments")
    before = source_state()
    handler = b'  elif [ "$?" -ne 1 ]; then\n    GLOBAL_LEAK_CHECK_ERROR=1\n    return 2\n'
    require(candidate.count(handler) == 2, "grep-handler-count")
    first, middle, last = candidate.split(handler)
    no_raw_sticky = first + handler.replace(b"    GLOBAL_LEAK_CHECK_ERROR=1\n", b"") + middle + handler + last
    no_encoded_sticky = first + handler + middle + handler.replace(b"    GLOBAL_LEAK_CHECK_ERROR=1\n", b"") + last
    ignore_gate = replace_once(candidate, b'[ "$GLOBAL_LEAK_CHECK_ERROR" -eq 0 ] && ', b"")
    clear_clean = replace_once(candidate, b"  return 0\n}\n\n# Negative controls",
                              b"  GLOBAL_LEAK_CHECK_ERROR=0\n  return 0\n}\n\n# Negative controls")
    clear_empty = replace_once(candidate, b'[ -n "$password" ] || return 0',
                              b'[ -n "$password" ] || { GLOBAL_LEAK_CHECK_ERROR=0; return 0; }')
    loud = candidate
    for pattern in (b'"$password" -- "$OUT" "$ERR"', b'"$encoded_plain" -- "$OUT" "$ERR"'):
        loud = replace_once(loud, pattern + b" >/dev/null 2>&1; then", pattern + b"; then")
    try:
        with tempfile.TemporaryDirectory(prefix="transport-grep-") as directory:
            work = Path(directory)
            baseline, total = observe(original, "baseline-healthy", work, new_controls=False)
            observe(tests, "new-controls-old-checker", work, baseline, total, rejected=GREP_LABELS[1:])
            observe(candidate, "candidate-healthy", work, baseline, total)
            for data, label, rejected in (
                    (no_raw_sticky, "omit-raw-sticky", [GREP_LABELS[i] for i in (1, 2, 5)]),
                    (no_encoded_sticky, "omit-encoded-sticky", [GREP_LABELS[i] for i in (3, 4, 6)]),
                    (ignore_gate, "ignore-aggregate-error", AGGREGATE_ERRORS + GREP_LABELS[1:]),
                    (clear_clean, "clear-on-clean", AGGREGATE_ERRORS + GREP_LABELS[1:]),
                    (clear_empty, "clear-on-empty", AGGREGATE_ERRORS + GREP_LABELS[1:]),
                    (loud, "leaky-grep-diagnostics", GREP_LABELS[1:])):
                observe(data, label, work, baseline, total, rejected=rejected)
            for phase, status in ((1, 2), (2, 7)):
                observe(original, f"baseline-real-case1-grep-{phase}", work, baseline, total,
                        new_controls=False, phase=phase, status=status)
                observe(candidate, f"candidate-real-case1-grep-{phase}", work, baseline, total,
                        phase=phase, status=status, aggregate_error=True)
            observe(candidate, "candidate-restored", work, baseline, total)
    finally:
        TARGET.write_bytes(candidate)
        require(source_state() == before, "restored-source-identity")
        git("diff", "--exit-code", "--quiet", "HEAD", "--")
    print("PASS 14 complete transport observations and restored tracked source identities", flush=True)


if __name__ == "__main__":
    try:
        main()
    except BaseException as error:
        label = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print("FAIL grep validation: " + label, flush=True)
        raise SystemExit(1)
