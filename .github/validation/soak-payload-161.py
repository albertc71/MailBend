"""Hosted-only synthetic sensitivity checks against unchanged unittest methods."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

original_root, candidate_root = map(Path, sys.argv[1:])
target = "test_comparison_windows_have_identical_mix"


def load(root, name):
    path = root / "tests/test-soak-contract.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(module, label, full=False, change=None):
    method = module.soak.request
    seen = {500: [], 5000: []}
    hits = {500: [], 5000: []}
    count = 500
    previous = None

    def request(ident, index):
        nonlocal count, previous
        if previous is not None and index < previous:
            assert count == 500, "unexpected third request profile"
            count = 5000
        previous = index
        seen[count].append(index)
        payload = method(ident, index)
        before = json.loads(json.dumps(payload))
        late = index >= count - count // 10
        if change == "late-tool-name" and late and index % 10 == 2:
            payload["params"]["name"] = "mail_get"
        elif change == "late-search-limit" and late and index % 10 == 2:
            payload["params"]["arguments"]["limit"] = 1
        elif change == "invalid-uid" and late and index % 10 == 7:
            payload["params"]["arguments"]["uid"] = 1
        elif change == "uniform-slot" and index % 10 == 2:
            payload["params"] = {"name": "mail_get", "arguments": {"uid": 1}}
        elif change == "ids":
            payload["id"] = ident + 100000
        elif change == "formatting":
            formatted = json.dumps(payload, indent=4, sort_keys=True)
            assert formatted != json.dumps(payload), "formatting control did not change representation"
            payload = json.loads(formatted)
            assert list(payload) != list(before), "formatting control did not reorder keys"
        if before != payload:
            hits[count].append(index)
        return payload

    suite = (unittest.defaultTestLoader.loadTestsFromTestCase(module.SoakContract) if full
             else unittest.TestSuite([module.SoakContract(target)]))
    output = io.StringIO()
    if full:
        result = unittest.TextTestRunner(stream=output, verbosity=2).run(suite)
    else:
        with patch.object(module.soak, "request", request):
            result = unittest.TextTestRunner(stream=output, verbosity=2).run(suite)
    print(label, "tests", result.testsRun, "failures", len(result.failures),
          "errors", len(result.errors), "skips", len(result.skipped), flush=True)
    assert not result.errors and not result.skipped, output.getvalue()
    assert result.testsRun == (9 if full else 1), output.getvalue()
    if full:
        print(output.getvalue(), flush=True)
        assert result.wasSuccessful(), output.getvalue()
        return
    expected_starts = ((0, 450, 0, 4500) if module is original
                       else (50, 500, 50, 4550))
    for size, head, tail in ((500, *expected_starts[:2]), (5000, *expected_starts[2:])):
        expected_indices = list(range(head, head + size // 10)) + list(range(tail, tail + size // 10))
        assert seen[size] == expected_indices, (label, size, "wrong actual request indices")
    negative = change in ("late-tool-name", "late-search-limit", "invalid-uid", "uniform-slot")
    if negative:
        assert all(hits.values()), (label, "mutation did not exercise both profiles")
        print(label, "changed requests", {size: len(indices) for size, indices in hits.items()}, flush=True)
    if change == "ids":
        assert hits == seen, "ID-only control did not change every request ID"
    if negative and module is candidate:
        assert len(result.failures) == sum(map(len, hits.values())), output.getvalue()
        for case, traceback in result.failures:
            assert target in case.id(), case.id()
            assert "comparison-window payload" in traceback, traceback
            assert "AssertionError" in traceback, traceback
            difference = {"late-tool-name": "mail_get", "late-search-limit": '"limit": 1',
                          "invalid-uid": '"uid": 1', "uniform-slot": "mail_get"}[change]
            assert difference in traceback, traceback
        assert len(output.getvalue()) <= 1048576, "control output exceeded 1 MiB"
        print(output.getvalue(), flush=True)
        print(label, "all failures are intended real payload assertions", flush=True)
    else:
        assert result.wasSuccessful(), output.getvalue()


paths = [root / "tests" / name for root in (original_root, candidate_root)
         for name in ("test-soak.py", "test-soak-contract.py")]
before = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
print("INPUT_SHA256", json.dumps(before, sort_keys=True), flush=True)
original = load(original_root, "original_contract")
candidate = load(candidate_root, "candidate_contract")
for module, label in ((original, "original"), (candidate, "candidate")):
    run(module, label + "-full", full=True)
    run(module, label + "-unmodified")
    for control in ("ids", "formatting", "late-tool-name", "late-search-limit", "invalid-uid", "uniform-slot"):
        run(module, label + "-" + control, change=control)
    run(module, label + "-restored-full", full=True)
assert before == {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
print("PASS restored source identities; synthetic controls only, no live soak", flush=True)
