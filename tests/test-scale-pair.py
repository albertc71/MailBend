#!/usr/bin/env python3
"""Small synthetic/mock controls: never build or execute a MailBend workload."""
import copy
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("scale_pair", ROOT / "tests/scale_pair.py")
pair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pair)


def sample(count, value=1):
    return {"status": "passed", "exit_code": 0, "timed_out": False, "memory_stop": None,
            "wall_seconds": value, "peak_rss_kib": 1024, "sampled_group_peak_rss_kib": 1024, "imap_logins": 1,
            "work": {"fixture_count": count, "body_bytes_fetched": 0,
                     "smtp_messages": 0, "typesafe_requests": 0}}


class PairTests(unittest.TestCase):
    def setUp(self):
        self.context = pair.comparator(ROOT)
        self.h = self.context.__enter__()
        self.addCleanup(self.context.__exit__, None, None, None)

    def reports(self):
        report = {"status": "measured", "profile": {"cpu": "unknown-but-identical"},
                  "scenarios": {s.name: self.h.summarize([sample(s.count) for _ in range(5)])
                                for s in self.h.SCENARIOS}}
        return {side: copy.deepcopy(report) for side in pair.SIDES}

    def order(self):
        return [{"scenario": s.name, "pair": i + 1, "side": side}
                for s in self.h.SCENARIOS for i in range(5)
                for side in (("reference", "candidate") if i in (0, 2, 4) else ("candidate", "reference"))]

    def test_paired_ratios_not_ratio_of_medians(self):
        reports = self.reports()
        name = self.h.SCENARIOS[0].name
        for side, values in zip(pair.SIDES, ([0.01, 0.02, 1, 2, 3], [0.01, 0.02, 10, 2, 3])):
            reports[side]["scenarios"][name] = self.h.summarize([sample(100000, x) for x in values])
        gates = pair.ratio_gate(self.h, reports, self.order())
        self.assertEqual(gates[name]["wall_seconds"]["median_ratio"], 1)
        self.assertTrue(gates[name]["wall_seconds"]["passed"])
        self.assertTrue(self.h.compare(reports["reference"], reports["candidate"]))
        for side, values in zip(pair.SIDES, ([0.001, 0.01, 0.1, 1, 10], [0.002, 0.02, 0.2, 0.001, 0.01])):
            reports[side]["scenarios"][name] = self.h.summarize([sample(100000, x) for x in values])
        self.assertFalse(pair.ratio_gate(self.h, reports, self.order())[name]["wall_seconds"]["passed"])
        self.assertFalse(self.h.compare(reports["reference"], reports["candidate"]))

    def test_ratio_boundary_passes_at_125_percent_and_fails_at_126(self):
        for ratio, expected in ((1.25, True), (1.26, False)):
            with self.subTest(ratio=ratio):
                reports = self.reports()
                for scenario in self.h.SCENARIOS:
                    for side in pair.SIDES:
                        samples = reports[side]["scenarios"][scenario.name]["samples"]
                        for row in samples:
                            factor = ratio if side == "candidate" else 1
                            row["wall_seconds"] = 10 * factor
                            row["peak_rss_kib"] = 100000 * factor
                        reports[side]["scenarios"][scenario.name] = self.h.summarize(samples)
                gates = pair.ratio_gate(self.h, reports, self.order())
                for metrics in gates.values():
                    for key in ("wall_seconds", "peak_rss_kib"):
                        self.assertEqual(metrics[key]["median_ratio"], ratio)
                        self.assertEqual(metrics[key]["passed"], expected)
                    self.assertTrue(metrics["imap_logins"]["passed"])

    def test_invalid_or_incomplete_evidence_cannot_pass(self):
        for change in ("missing", "failed", "profile", "samples", "order", "login", "nan"):
            with self.subTest(change=change):
                reports, order = self.reports(), self.order()
                name = self.h.SCENARIOS[0].name
                samples = reports["reference"]["scenarios"][name]["samples"]
                if change == "missing":
                    del reports["reference"]["scenarios"][name]
                elif change == "failed":
                    samples[0]["status"] = "failed"
                elif change == "profile":
                    reports["candidate"]["profile"]["cpu"] = "different"
                elif change == "samples":
                    samples.pop()
                elif change == "order":
                    order[0], order[1] = order[1], order[0]
                elif change == "login":
                    samples[0]["imap_logins"] = 3
                    reports["reference"]["scenarios"][name] = self.h.summarize(samples)
                else:
                    samples[0]["wall_seconds"] = float("nan")
                with self.assertRaises(ValueError):
                    pair.ratio_gate(self.h, reports, order)
        self.assertEqual(len(pair.ratio_gate(self.h, self.reports(), self.order())), 7)

    def test_absolute_budgets_apply_even_when_both_sides_equal(self):
        for key, value in (("wall_seconds", 90.001), ("peak_rss_kib", 3145729),
                           ("sampled_group_peak_rss_kib", 3145729),
                           ("sampled_group_peak_rss_kib", None),
                           ("sampled_group_peak_rss_kib", float("inf")),
                           ("sampled_group_peak_rss_kib", -1)):
            with self.subTest(key=key, value=value):
                reports = self.reports()
                name = self.h.SCENARIOS[0].name
                for side in pair.SIDES:
                    samples = reports[side]["scenarios"][name]["samples"]
                    for row in samples:
                        row[key] = value
                    reports[side]["scenarios"][name] = self.h.summarize(samples)
                with self.assertRaises(ValueError):
                    pair.ratio_gate(self.h, reports, self.order())
        row = sample(100000, 90)
        row.update(peak_rss_kib=3145728, sampled_group_peak_rss_kib=0)
        pair.absolute_sample(self.h, self.h.SCENARIOS[0], row)

    def test_routing_changes_only_argv_zero_and_restores_on_error(self):
        command = [str(ROOT / "scripts/mailbend"), "call", "tool", '{"x":1}']
        env, work, control = {"SAFE": "value"}, object(), object()
        original = mock.Mock(side_effect=RuntimeError("test"))
        self.h.measure = original
        with self.assertRaises(RuntimeError):
            with pair.route_launcher(self.h, ROOT, pathlib.Path("/other/scripts/mailbend")):
                self.h.measure(command, env, work, 72, control)
        self.assertIs(self.h.measure, original)
        args = original.call_args.args
        self.assertEqual(args[0], ["/other/scripts/mailbend", *command[1:]])
        self.assertIs(args[1], env)
        self.assertIs(args[2], work)
        self.assertEqual(args[3], 72)
        self.assertIs(args[4], control)
        self.assertEqual(command[0], str(ROOT / "scripts/mailbend"))
        with pair.route_launcher(self.h, ROOT, pathlib.Path("/other/scripts/mailbend")):
            with self.assertRaises(ValueError):
                self.h.measure(["wrong"], env, work, 72, control)

    def test_active_budget_includes_cleanup_and_excludes_idle(self):
        now = [0.0]
        outer = types.SimpleNamespace(check=lambda: None, remaining=lambda limit: limit)
        control = pair.SideControl(outer, clock=lambda: now[0])
        with control.active():
            now[0] += 100
            self.assertEqual(control.remaining(1000), 800)
        now[0] += 10000  # Other side's active work does not charge this side.
        self.assertEqual(control.used(), 100)
        with self.assertRaises(TimeoutError):
            with control.active():
                try:
                    now[0] += 790
                finally:
                    now[0] += 11  # Cleanup must not allow a late sample to pass.
        self.assertEqual(control.used(), 901)
        self.assertIsNone(control.started)

    def test_all_seventy_samples_alternate_leaders_and_retain_partial_failures(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as temp:
                out = pathlib.Path(temp)
                roots = (ROOT, out / "candidate")
                identity = {"adapter_sha256": "adapter", "checkouts": {
                    side: {"source_sha": side, "files": {"bin/mailbend-core": {"sha256": side}}}
                    for side in pair.SIDES}}
                calls = []
                self.h.profile = lambda: {"cpu": "new-family"}
                self.h.certificates = lambda *_: out
                def measure(command, env, work, timeout, control):
                    calls.append(command[0])
                    return None
                self.h.measure = measure
                def run_sample(scenario, work, certs, control):
                    self.h.measure([str(ROOT / "scripts/mailbend"), "call"], {}, work, 90, control)
                    pair_number = ((len(calls) - 1) % 10) // 2 + 1
                    factor = 1.25 if calls[-1] == str(roots[1] / "scripts/mailbend") else 1
                    row = sample(scenario.count, pair_number * factor)
                    if fail and len(calls) == 3:
                        row["status"] = "failed"
                        row["reason"] = "synthetic failure"
                    return row
                self.h.run_sample = run_sample
                with self.h.RunControl(pair.time.monotonic() + 30) as outer:
                    if fail:
                        with self.assertRaises(ValueError):
                            pair.collect(self.h, roots, identity, out, outer)
                    else:
                        result = pair.collect(self.h, roots, identity, out, outer)
                        self.assertEqual(result["order"], self.order())
                        self.assertEqual(len(calls), 70)
                        self.assertEqual(calls, [str(roots[side] / "scripts/mailbend")
                                                 for _ in range(7) for side in (0, 1, 1, 0, 0, 1, 1, 0, 0, 1)])
                        self.assertEqual(result["status"], "measurements-passed-identity-check-pending")
                        for metrics in result["gates"].values():
                            self.assertEqual(metrics["wall_seconds"]["ratios"], [1.25] * 5)
                if fail:
                    result = pair.load_json(out / "paired-result.json")
                    self.assertEqual(result["status"], "failed")
                    self.assertEqual(len(result["order"]), 3)
                    report = pair.load_json(out / "candidate-results.json")
                    self.assertEqual(report["scenarios"][self.h.SCENARIOS[0].name]["samples"][-1]["reason"], "synthetic failure")

    def test_identity_tamper_and_hardlink_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            original = root / "binary"
            original.write_text("old")
            pair.regular(root, "binary")
            (root / "alias").hardlink_to(original)
            with self.assertRaises(ValueError):
                pair.regular(root, "binary")
            pair.write_json(root / "paired-identities.json", {"binary": "old"})
            with mock.patch.object(pair, "identities", return_value={"binary": "changed"}):
                with self.assertRaises(ValueError):
                    pair.unchanged((root, root), "a" * 40, root)

    def test_wrong_source_and_candidate_own_reference_rejected(self):
        with self.assertRaises(ValueError):
            pair.preflight(ROOT, ROOT.parent / "other", pair.REFERENCE_SHA)
        with mock.patch.object(pair, "git", return_value=b"wrong\n"):
            with self.assertRaisesRegex(ValueError, "wrong source SHA"):
                pair.preflight(ROOT, ROOT.parent / "other", "a" * 40)

    def test_isolated_cli_ignores_ambient_imports_before_preflight(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            sentinel = root / "ambient-import-ran"
            attack = f"from pathlib import Path\nPath({str(sentinel)!r}).touch()\nraise RuntimeError('ambient module executed')\n"
            for name in ("json.py", "argparse.py"):
                (root / name).write_text(attack)
            command = [sys.executable, "-I", str(ROOT / "tests/scale_pair.py"), "--help"]
            result = subprocess.run(command, cwd=root, env={**os.environ, "PYTHONPATH": str(root)},
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("preflight", result.stdout)
            self.assertFalse(sentinel.exists())
            # The fixture must actually intercept an unisolated invocation.
            result = subprocess.run([sys.executable, "-c", "import json"], cwd=root,
                                    env={**os.environ, "PYTHONPATH": str(root)},
                                    capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(sentinel.exists())

    def test_actual_workflow_record_guard_and_candidate_only_report_rejected(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        section = workflow.split("- name: Refuse evidence-only mode outside explicit manual dispatch", 1)[1]
        body = section.split("        run: |\n", 1)[1].split("      - ", 1)[0]
        script = "\n".join(line[10:] for line in body.splitlines())
        for event, record, expected in (("pull_request", "true", 1), ("schedule", "true", 1),
                                        ("workflow_dispatch", "true", 0), ("pull_request", "false", 0)):
            proc = subprocess.run(["sh", "-c", script], env={**os.environ, "EVENT_NAME": event,
                                  "RECORD_SCALE": record}, capture_output=True, timeout=2)
            self.assertEqual(proc.returncode, expected)
        with tempfile.TemporaryDirectory() as temp:
            output = pathlib.Path(temp)
            pair.write_json(output / "candidate-results.json", self.reports()["candidate"])
            args = types.SimpleNamespace(phase="run", reference=ROOT, candidate=ROOT.parent / "other",
                                         candidate_sha="a" * 40, output_dir=output)
            with mock.patch.object(pair, "preflight", return_value=(args.reference, args.candidate)):
                with self.assertRaisesRegex(ValueError, "does not reuse reports"):
                    pair.run(args)

    def test_apparatus_import_tamper_fails_before_execution(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            path = root / "tests/scale_support/v1/image_fixtures.py"
            path.parent.mkdir(parents=True)
            path.write_text("raise RuntimeError('must not execute')")
            with self.assertRaisesRegex(ValueError, "apparatus changed before import"):
                with pair.comparator(root):
                    self.fail("tampered source imported")

    def test_wrong_tag_rejected_after_correct_clean_head(self):
        def git(root, *args):
            if args == ("rev-parse", "HEAD"):
                return (pair.REFERENCE_SHA + "\n").encode()
            if args == ("status", "--porcelain", "--untracked-files=no"):
                return b""
            if args == ("rev-parse", "refs/tags/scale-reference-v1^{commit}"):
                return b"0000000000000000000000000000000000000000\n"
            self.fail(f"unexpected git operation {args}")
        with mock.patch.object(pair, "git", side_effect=git):
            with self.assertRaisesRegex(ValueError, "reference tag does not resolve"):
                pair.preflight(ROOT, ROOT.parent / "other", "a" * 40)

    def test_caps_match_fixed_reference_baseline_provenance(self):
        raw = (ROOT / "tests/scale-baseline.json").read_bytes()
        self.assertEqual(pair.sha(raw), pair.HISTORICAL_SHA256)
        data = json.loads(raw)
        self.assertEqual(data["source_commit"], pair.REFERENCE_SHA)
        for name, cap in pair.LOGIN_CAPS.items():
            counts = {s["imap_logins"] for s in data["scenarios"][name]["samples"]}
            self.assertEqual(len(counts), 1)
            self.assertEqual(cap, int(counts.pop() * 1.25))


if __name__ == "__main__":
    unittest.main()
