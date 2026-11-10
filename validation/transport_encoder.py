"""Bounded, synthetic observations of the complete transport test runner."""
import hashlib
import itertools
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

BASE = "a5896b2896d934d0f1566b1da42fd99a4b2cad47"
REJECTED = "137b70e83bb2445a16af5471424d30025af9d2cc"
REJECTED_HASH = "804cf4e1c090179e549e7f0958b70c685416c0e5204e7cbb69f15104d7c9063b"
PRODUCT = "1e8918fab6bfa7a396fbdb7b61189c34b7a78566"
PRODUCT_TREE = "22543244e8fda964aa375b8e780444d2a2b394d0"
BASE_HASH = "db8a5d8cda0d159060338a5477663efd0bb26935c5fd4c9d5c257225dcbcc491"
CANDIDATE_HASH = "68b0e1a30cbbbb7b9b1def0ea9c9663dacc437222f246eb8c37c9c0a38e5a47b"
SCRIPT = "tests/test-transport.sh"
ADDITIONS = [".github/workflows/transport-encoder-validation.yml", "validation/transport_encoder.py"]
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
    require(git("rev-list", "--parents", "-n", "1", PRODUCT).decode().split() == [PRODUCT, REJECTED],
            "product-parent")
    require(git("rev-list", "--parents", "-n", "1", REJECTED).decode().split() == [REJECTED, BASE],
            "rejected-parent")
    require(git("diff", "--name-status", "--no-renames", REJECTED, PRODUCT, "--") ==
            f"M\t{SCRIPT}\n".encode(), "correction-change")
    require(git("rev-parse", PRODUCT + "^{tree}").decode().strip() == PRODUCT_TREE, "product-tree")
    require(git("diff", "--name-status", "--no-renames", BASE, PRODUCT, "--") ==
            f"M\t{SCRIPT}\n".encode(), "product-change")
    require(git("diff", "--name-status", "--no-renames", PRODUCT, "HEAD", "--") ==
            "".join(f"A\t{path}\n" for path in ADDITIONS).encode(), "validation-additions")
    for revision in (BASE, REJECTED, PRODUCT, "HEAD"):
        require(git("ls-tree", revision, "--", SCRIPT).startswith(b"100755 blob "), "script-mode")
    candidate = TARGET.read_bytes()
    baseline = git("show", f"{BASE}:{SCRIPT}")
    rejected = git("show", f"{REJECTED}:{SCRIPT}")
    require(digest(candidate) == CANDIDATE_HASH and digest(baseline) == BASE_HASH
            and digest(rejected) == REJECTED_HASH, "source-hashes")
    print(f"validation-head={chain[0]} product-head={PRODUCT} product-tree={PRODUCT_TREE}")
    return baseline, rejected, candidate


ATTRIBUTION = [f"PASS 18 attribution {protocol} {form} {stream}".encode()
               for protocol, form, stream in itertools.product(
                   ("imap", "smtp"), ("clean", "raw", "login", "plain"), ("stdout", "stderr"))]
ENCODER_PASS = [f"PASS 18 encoder failure {i} is distinct and redacted".encode() for i in range(1, 5)]
ENCODER_FAIL = [f"FAIL 18 encoder failure {i} -- wrong verdict, aggregate, or unsafe diagnostic".encode()
                for i in range(1, 5)]
CLEAN = b"PASS 18 echoed credentials never reach the transcript\n"
DIAGNOSTICS = {
    1: b"FAIL 18 echoed credentials never reach the transcript -- imap exit=0 leak_check=2\n",
    2: b"FAIL 18 echoed credentials never reach the transcript -- imap exit=0 leak_check=2\n",
    3: b"FAIL 18 echoed credentials never reach the transcript --  smtp exit=0 leak_check=2\n",
    4: b"FAIL 18 echoed credentials never reach the transcript --  smtp exit=0 leak_check=2\n",
}
PRIVATE_MARKER = b"case18-encoder-password\n"
ANCHOR = b'      case18\n      [ "$FAIL_COUNT" -eq 1 ]'
OBSERVER = b'''      case18
      observed_hash=$(sha256sum "$diagnostic")
      printf '%s %s %s %s %s\\n' "$failure" "$FAIL_COUNT" "$PASS_COUNT" "$GLOBAL_LEAK" "${observed_hash%% *}" >>"$ENCODER_VALIDATION_EVIDENCE"
      [ "$FAIL_COUNT" -eq 1 ]'''


def observed_records(kind):
    records = []
    for i in range(1, 5):
        diagnostic = DIAGNOSTICS[i]
        failed, passed = 1, 0
        if kind == "old-checker":
            diagnostic = PRIVATE_MARKER + CLEAN
            failed, passed = 0, 1
        elif kind == "status-one":
            diagnostic = diagnostic.replace(b"leak_check=2", b"leak_check=1")
        elif kind == "no-pipefail":
            diagnostic = CLEAN
            failed, passed = 0, 1
        elif kind in ("rejected-original", "public-stderr"):
            diagnostic = PRIVATE_MARKER + diagnostic
        records.append(f"{i} {failed} {passed} 0 {digest(diagnostic)}\n")
    return "".join(records).encode()


def observe(data, label, kind, work):
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
               ENCODER_VALIDATION_EVIDENCE=str(evidence))
    with capture.open("wb") as output:
        result = subprocess.run(["timeout", "--signal=TERM", "--kill-after=10s", f"{seconds}s",
                                 "bash", SCRIPT], cwd=ROOT, env=env, stdout=output,
                                stderr=subprocess.STDOUT, check=False, timeout=seconds + 15)
    require(time.monotonic() < DEADLINE, "experiment-budget")
    require(capture.stat().st_size <= LIMIT and evidence.stat().st_size <= 4096, "capture-size")
    output = capture.read_bytes()
    lines = output.splitlines()
    failing = kind not in ("baseline", "candidate")
    expected_code = 1 if failing else 0
    expected_passed = 243 if baseline or failing else 247
    expected_failed = 4 if failing else 0
    print(f"{label}: exit={result.returncode} bytes={len(output)} sha256={digest(output)}")
    require(result.returncode == expected_code, "runner-status")
    require([line for line in lines if line.startswith(b"transport:")] ==
            [f"transport: {expected_passed} passed, {expected_failed} failed".encode()], "runner-counts")
    require([line for line in lines if line.startswith(b"FAIL ")] ==
            (ENCODER_FAIL if failing else []), "failure-reason")
    require([line for line in lines if line.startswith((b"PASS 18 attribution ", b"FAIL 18 attribution "))]
            == ATTRIBUTION, "existing-exact-oracle")
    require([line for line in lines if line.startswith((b"PASS 18 encoder failure ", b"FAIL 18 encoder failure "))]
            == ([] if baseline else ENCODER_FAIL if failing else ENCODER_PASS), "encoder-controls")
    require(lines.count(b"PASS 2 password never leaks; LOGIN/AUTH redacted in the log") == 1,
            "aggregate-control")
    require(lines[-1] == f"transport: {expected_passed} passed, {expected_failed} failed".encode(),
            "runner-completion")
    require(PRIVATE_MARKER not in output, "private-marker-in-output")
    require(evidence.read_bytes() == (b"" if baseline else observed_records(kind)), "observed-diagnostic-reason")
    require(source_state() == before, "runner-source-change")
    print(f"PASS {label}: passed={expected_passed} failed={expected_failed} exact-attribution=16 diagnostic-records={0 if baseline else 4}")


def replace_once(data, old, new):
    require(data.count(old) == 1, "mutation-anchor")
    return data.replace(old, new)


def main():
    baseline, rejected, candidate = admit()
    if sys.argv[1:] == ["--admit-only"]:
        return
    require(not sys.argv[1:], "arguments")
    before = source_state()
    start = b"check_leak() {\n"
    end = b"\n# Negative controls for the checker itself."
    require(candidate.count(start) == baseline.count(start) == 1, "checker-start")
    require(candidate.count(end) == baseline.count(end) == 1, "checker-end")
    old_checker = baseline.split(start)[1].split(end)[0]
    new_checker = candidate.split(start)[1].split(end)[0]
    red = replace_once(candidate, new_checker, old_checker)
    require(candidate.count(b"} 2>/dev/null) || return 2") == 2, "status-mutation-count")
    require(candidate.count(b"set -o pipefail; ") == 2, "pipefail-mutation-count")
    status_one = candidate.replace(b"} 2>/dev/null) || return 2", b"} 2>/dev/null) || return 1")
    no_pipefail = candidate.replace(b"set -o pipefail; ", b"")
    public_stderr = candidate.replace(b"} 2>/dev/null) || return 2", b"}) || return 2")
    try:
        with tempfile.TemporaryDirectory(prefix="transport-encoder-") as directory:
            work = Path(directory)
            for data, label, kind in [
                    (baseline, "baseline-healthy", "baseline"),
                    (red, "new-controls-old-checker", "old-checker"),
                    (rejected, "rejected-original-candidate", "rejected-original"),
                    (candidate, "candidate-healthy", "candidate"),
                    (status_one, "mutant-status-one", "status-one"),
                    (no_pipefail, "mutant-no-pipefail", "no-pipefail"),
                    (public_stderr, "mutant-public-stderr", "public-stderr"),
                    (candidate, "candidate-restored", "candidate")]:
                observe(data, label, kind, work)
    finally:
        TARGET.write_bytes(candidate)
        require(source_state() == before, "restored-source-identity")
        git("diff", "--no-ext-diff", "--exit-code", "--quiet", "HEAD", "--")
    print("PASS encoder sensitivity and restored tracked source identities")


if __name__ == "__main__":
    try:
        main()
    except BaseException as error:
        label = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print("FAIL encoder validation: " + label)
        raise SystemExit(1)
