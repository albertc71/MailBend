"""Bounded hosted controls for the soak profile selector guard."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path("source").resolve()
BASE = "ea1f5dd7564253cd76b817927aa8c58f4a6dd10f"
HEAD = os.environ["CANDIDATE_SHA"]
SELECTOR = 'count, budget = (500, 180) if profile == "short" else (5000, 1800)'
TEST = "test_profile_workloads_match_comparison_windows"
DIAGNOSTIC = "soak profile counts or budgets changed; revisit comparison windows"


def source(revision, name):
    return subprocess.check_output(
        ["git", "show", f"{revision}:tests/{name}"], cwd=ROOT, timeout=30)


runner = source(HEAD, "test-soak.py")
assert runner == source(BASE, "test-soak.py"), "candidate changed runner"
baseline = source(BASE, "test-soak-contract.py")
candidate = source(HEAD, "test-soak-contract.py")
assert runner.decode().count(SELECTOR) == 1, "mutation selector must be unique"
before = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, timeout=30)
assert before == b"", "candidate checkout starts dirty"
for label, data in (("runner", runner), ("baseline-contract", baseline),
                    ("candidate-contract", candidate)):
    print(label, hashlib.sha256(data).hexdigest(), flush=True)


def check(label, contract, replacement, rejected=False):
    mutated = runner.decode().replace(SELECTOR, replacement).encode()
    if replacement != SELECTOR:
        assert mutated != runner, "mutation did not change source"
    with tempfile.TemporaryDirectory(prefix="soak-count-control-") as directory:
        work = Path(directory)
        (work / "test-soak.py").write_bytes(mutated)
        (work / "test-soak-contract.py").write_bytes(contract)
        result = subprocess.run([sys.executable, "-B", "test-soak-contract.py", "-v"],
                                cwd=work, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=60)
        print(f"CASE {label} exit={result.returncode}", flush=True)
        print(result.stdout, flush=True)
        expected_count = 10 if contract == candidate else 9
        assert f"Ran {expected_count} tests" in result.stdout, "incomplete suite"
        if rejected:
            assert result.returncode == 1, "mutant did not fail normally"
            assert f"FAIL: {TEST} " in result.stdout, "wrong failing test"
            assert DIAGNOSTIC in result.stdout, "missing intended selector assertion"
            assert "FAILED (failures=1)" in result.stdout, "unexpected failures or errors"
        else:
            assert result.returncode == 0 and "\nOK\n" in result.stdout, "healthy control failed"
        assert (work / "test-soak.py").read_bytes() == mutated
        assert (work / "test-soak-contract.py").read_bytes() == contract
    print(f"PASS {label}", flush=True)


mutations = (
    ("short-600", SELECTOR.replace("(500, 180)", "(600, 180)")),
    ("long-6000", SELECTOR.replace("(5000, 1800)", "(6000, 1800)")),
)
check("baseline-healthy", baseline, SELECTOR)
for name, replacement in mutations:
    check("baseline-survives-" + name, baseline, replacement)
check("candidate-healthy", candidate, SELECTOR)
for name, replacement in mutations + (
    ("branch-not-equal", SELECTOR.replace('== "short"', '!= "short"')),
    ("profile-counts-swapped", 'count, budget = (5000, 180) if profile == "short" else (500, 1800)'),
):
    check("candidate-rejects-" + name, candidate, replacement, rejected=True)
check("candidate-equivalent-format", candidate,
      "count, budget = (\n        (500, 180) if profile == 'short' else (5000, 1800)\n    )")
check("candidate-restored", candidate, SELECTOR)
assert source(HEAD, "test-soak.py") == runner
assert source(HEAD, "test-soak-contract.py") == candidate
assert subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, timeout=30) == before
print("PASS exact candidate restoration and clean checkout", flush=True)
