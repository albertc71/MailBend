#!/usr/bin/env python3
"""Small synthetic/mock controls: never build or execute a MailBend workload."""
import copy
import importlib.util
import json
import os
import pathlib
import re
import shutil
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


def historical_scripts():
    return {"scripts/mailbend": b"#!/bin/sh\n# historical launcher fixture\n",
            "scripts/install.sh": b"#!/bin/sh\n# historical installer fixture\n",
            **{name: (ROOT / name).read_bytes() for name in pair.INSTALLERS[1:]}}


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

    def test_complete_installer_migration_through_real_preflight(self):
        # Keep filesystem validation, source hashing and preflight real. Only Git
        # metadata and the reviewed new tuple use small synthetic fixtures here.
        names = ("scripts/mailbend", *pair.INSTALLERS)
        original = historical_scripts()
        revised = {name: original[name] + b"\n# synthetic reviewed revision\n"
                   for name in pair.INSTALLERS[1:]}
        allowed = tuple(pair.sha(revised[name]) for name in pair.INSTALLERS[1:])
        for case in ("old", "new", "mixed", "reference-new", "wrong-path",
                     "changed-bend", "changed-rust", "changed-lean",
                     "launcher-reference", "launcher-candidate", "install-reference",
                     "install-candidate", "apparatus-reference", "apparatus-candidate",
                     "missing", "symlink", "hardlink", "dirty", "wrong-head", "wrong-tag"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as tmp:
                roots = tuple(pathlib.Path(tmp) / side for side in pair.SIDES)
                for root in roots:
                    for name in (*pair.PINNED, *names):
                        path = root / name
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(original[name] if name in original else (ROOT / name).read_bytes())
                for name, data in revised.items():
                    if case != "old":
                        (roots[1] / name).write_bytes(data)
                if case == "mixed":
                    (roots[1] / pair.INSTALLERS[1]).write_bytes(original[pair.INSTALLERS[1]])
                elif case == "reference-new":
                    (roots[0] / pair.INSTALLERS[1]).write_bytes(revised[pair.INSTALLERS[1]])
                elif case == "wrong-path":
                    (roots[1] / pair.INSTALLERS[1]).write_bytes(revised[pair.INSTALLERS[2]])
                elif case.startswith("changed-"):
                    name = "scripts/install-" + case.split("-")[1] + ".sh"
                    (roots[1] / name).write_bytes(revised[name] + b"x")
                elif case.startswith(("launcher-", "install-", "apparatus-")):
                    kind, side = case.split("-")
                    name = {"launcher": "scripts/mailbend", "install": "scripts/install.sh",
                            "apparatus": "tests/test-scale.py"}[kind]
                    (roots[pair.SIDES.index(side)] / name).write_bytes(b"changed")
                elif case in ("missing", "symlink", "hardlink"):
                    path = roots[1] / pair.INSTALLERS[1]
                    path.unlink()
                    if case in ("symlink", "hardlink"):
                        # Keep accepted revised bytes: bypassing regular() must
                        # not get caught incidentally by the mixed-tuple gate.
                        target = pathlib.Path(tmp) / "revised-bend.sh"
                        target.write_bytes(revised[pair.INSTALLERS[1]])
                        if case == "symlink":
                            path.symlink_to(target)
                        else:
                            path.hardlink_to(target)
                def git(root, *args):
                    if args == ("rev-parse", "HEAD"):
                        return ("0" * 40 if case == "wrong-head" else
                                pair.REFERENCE_SHA if root == roots[0] else "a" * 40).encode()
                    if args[0] == "status":
                        return b" M tracked" if case == "dirty" else b""
                    if args[0] == "rev-parse":
                        return ("0" * 40 if case == "wrong-tag" else pair.REFERENCE_SHA).encode()
                    self.assertEqual(args[0], "show")
                    return original[args[1].split(":", 1)[1]]
                with mock.patch.object(pair, "git", side_effect=git), \
                        mock.patch.object(pair, "CANDIDATE_HELPER_TUPLE", allowed):
                    if case in ("old", "new"):
                        self.assertEqual(pair.preflight(*roots, "a" * 40), roots)
                    elif case == "missing":
                        with self.assertRaises(FileNotFoundError):
                            pair.preflight(*roots, "a" * 40)
                    else:
                        expected = {
                            "mixed": "not a reviewed complete revision",
                            "wrong-path": "not a reviewed complete revision",
                            "changed-bend": "not a reviewed complete revision",
                            "changed-rust": "not a reviewed complete revision",
                            "changed-lean": "not a reviewed complete revision",
                            "reference-new": "fixed launcher/installer changed",
                            "launcher-reference": "fixed launcher/installer changed",
                            "launcher-candidate": "candidate launcher is not a reviewed revision",
                            "install-reference": "fixed launcher/installer changed",
                            "install-candidate": "candidate installer is not a reviewed revision",
                            "apparatus-reference": "apparatus changed",
                            "apparatus-candidate": "apparatus changed",
                            "symlink": "symlink forbidden",
                            "hardlink": "not an unaliased regular file",
                            "dirty": "tracked source is dirty",
                            "wrong-head": "wrong source SHA",
                            "wrong-tag": "reference tag does not resolve",
                        }[case]
                        with self.assertRaisesRegex(ValueError, expected):
                            pair.preflight(*roots, "a" * 40)

    def test_reviewed_installer_tuple_is_literal_and_path_ordered(self):
        self.assertEqual(pair.INSTALLERS[1:], ("scripts/install-bend.sh",
                         "scripts/install-rust.sh", "scripts/install-lean.sh"))
        self.assertEqual(pair.CANDIDATE_HELPER_TUPLE, (
            "57c7d071b6f0155c69058a883e83b97f6a76a17d438d9cce1d2b870576c2af1b",
            "0396875e0f8c09599c9badbe4fbde259b61138308977835fbf0c8b4c198c7a17",
            "4b30ca5f48136b481243ea0c819c970563e13e96ef660b8bd7ad8c738ce14374"))

    def test_reviewed_launcher_hash_is_literal(self):
        self.assertEqual(pair.CANDIDATE_LAUNCHER_SHA256,
                         "68cf6c6e6c671585d8752b653d8e76728d00306a1cd76b6f7723257d1546ffd8")
        self.assertEqual(pair.CANDIDATE_REPORT_LAUNCHER_SHA256,
                         "251f054ca4f223c180602b00c16192f08dc7ff88d77522951efbfd3a021af26e")

    def test_current_managed_scripts_pass_production_preflight_as_one_tuple(self):
        original = historical_scripts()
        names = ("scripts/mailbend", *pair.INSTALLERS)
        with tempfile.TemporaryDirectory() as tmp:
            roots = tuple(pathlib.Path(tmp) / side for side in pair.SIDES)
            for root in roots:
                for name in (*pair.PINNED, *names):
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(original[name] if name in original else (ROOT / name).read_bytes())
            current = {name: (ROOT / name).read_bytes() for name in pair.MANAGED_SCRIPT_PATHS}
            for name, data in current.items():
                (roots[1] / name).write_bytes(data)
            def git(root, *args):
                if args == ("rev-parse", "HEAD"):
                    return (pair.REFERENCE_SHA if root == roots[0] else "a" * 40).encode()
                if args[0] == "status":
                    return b""
                if args[0] == "rev-parse":
                    return pair.REFERENCE_SHA.encode()
                self.assertEqual(args[0], "show")
                return original[args[1].split(":", 1)[1]]
            with mock.patch.object(pair, "git", side_effect=git):
                self.assertEqual(pair.preflight(*roots, "a" * 40), roots)
                for name, data in current.items():
                    with self.subTest(tampered=name):
                        (roots[1] / name).write_bytes(data + b"\n# unknown bytes\n")
                        with self.assertRaisesRegex(ValueError, "not a reviewed revision"):
                            pair.preflight(*roots, "a" * 40)
                        (roots[1] / name).write_bytes(data)
                for name in pair.MANAGED_SCRIPT_PATHS[:2]:
                    with self.subTest(cross_pair=name):
                        (roots[1] / name).write_bytes(original[name])
                        with self.assertRaises(ValueError):
                            pair.preflight(*roots, "a" * 40)
                        (roots[1] / name).write_bytes(current[name])
                (roots[0] / "scripts/mailbend").write_bytes(current["scripts/mailbend"])
                with self.assertRaisesRegex(ValueError, "fixed launcher/installer changed"):
                    pair.preflight(*roots, "a" * 40)

    def test_candidate_launcher_migration_through_real_preflight(self):
        names = ("scripts/mailbend", *pair.INSTALLERS)
        original = historical_scripts()
        original["scripts/mailbend"] = b"#!/bin/sh\n# historical launcher fixture\n"
        revised = b"#!/bin/sh\n# independently approved launcher fixture\n"
        for case in ("original", "approved", "tampered", "reference-approved",
                     "symlink", "hardlink", "missing", "dirty", "post-run-drift"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as tmp:
                roots = tuple(pathlib.Path(tmp) / side for side in pair.SIDES)
                for root in roots:
                    for name in (*pair.PINNED, *names):
                        path = root / name
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(original[name] if name in original else
                                         (ROOT / name).read_bytes())
                launcher = roots[1] / "scripts/mailbend"
                if case != "original":
                    launcher.write_bytes(revised)
                if case == "tampered":
                    launcher.write_bytes(revised + b"changed")
                elif case == "reference-approved":
                    (roots[0] / "scripts/mailbend").write_bytes(revised)
                elif case in ("symlink", "hardlink", "missing"):
                    launcher.unlink()
                    target = pathlib.Path(tmp) / "approved-launcher"
                    target.write_bytes(revised)
                    if case == "symlink":
                        launcher.symlink_to(target)
                    elif case == "hardlink":
                        launcher.hardlink_to(target)
                def git(root, *args):
                    if args == ("rev-parse", "HEAD"):
                        return (pair.REFERENCE_SHA if root == roots[0] else "a" * 40).encode()
                    if args[0] == "status":
                        return b" M scripts/mailbend" if case == "dirty" else b""
                    if args[0] == "rev-parse":
                        return pair.REFERENCE_SHA.encode()
                    self.assertEqual(args[0], "show")
                    return original[args[1].split(":", 1)[1]]
                with mock.patch.object(pair, "git", side_effect=git), \
                        mock.patch.object(pair, "CANDIDATE_LAUNCHER_SHA256", pair.sha(revised)):
                    if case in ("original", "approved", "post-run-drift"):
                        self.assertEqual(pair.preflight(*roots, "a" * 40), roots)
                        if case == "post-run-drift":
                            for root in roots:
                                for name in (*pair.EXECUTABLES, "scripts/install.sh"):
                                    path = root / name
                                    path.parent.mkdir(parents=True, exist_ok=True)
                                    if not path.exists():
                                        path.write_bytes(name.encode())
                                    path.chmod(0o755)
                            output = pathlib.Path(tmp) / "reports"
                            output.mkdir()
                            pair.write_json(output / "paired-identities.json",
                                            pair.identities(roots, "a" * 40))
                            pair.unchanged(roots, "a" * 40, output)
                            launcher.write_bytes(original["scripts/mailbend"])
                            with self.assertRaisesRegex(ValueError, "identities changed"):
                                pair.unchanged(roots, "a" * 40, output)
                    elif case == "missing":
                        with self.assertRaises(FileNotFoundError):
                            pair.preflight(*roots, "a" * 40)
                    else:
                        expected = {
                            "tampered": "candidate launcher is not a reviewed revision",
                            "reference-approved": "fixed launcher/installer changed",
                            "symlink": "symlink forbidden",
                            "hardlink": "not an unaliased regular file",
                            "dirty": "tracked source is dirty",
                        }[case]
                        with self.assertRaisesRegex(ValueError, expected):
                            pair.preflight(*roots, "a" * 40)

    def test_historical_installer_migration_through_real_preflight(self):
        names = ("scripts/mailbend", *pair.INSTALLERS)
        original = historical_scripts()
        original["scripts/install.sh"] = b"#!/bin/sh\n# historical installer fixture\n"
        revised = b"#!/bin/sh\n# independently reviewed flat installer fixture\n"
        self.assertEqual(pair.CANDIDATE_INSTALLER_SHA256,
                         "ae7a0f7ef0c8606488cbd5414c5a3914a027fce6773b9cae2bdf865b9d564f9b")
        for case in ("original", "approved", "unknown", "reference-approved",
                     "symlink", "hardlink", "missing", "dirty", "post-run-drift"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as tmp:
                roots = tuple(pathlib.Path(tmp) / side for side in pair.SIDES)
                for root in roots:
                    for name in (*pair.PINNED, *names):
                        path = root / name
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(original[name] if name in original else
                                         (ROOT / name).read_bytes())
                installer = roots[1] / "scripts/install.sh"
                if case != "original":
                    installer.write_bytes(revised)
                if case == "unknown":
                    installer.write_bytes(revised + b"\n# unreviewed installer\n")
                elif case == "reference-approved":
                    (roots[0] / "scripts/install.sh").write_bytes(revised)
                elif case in ("symlink", "hardlink", "missing"):
                    installer.unlink()
                    target = pathlib.Path(tmp) / "approved-installer"
                    target.write_bytes(revised)
                    if case == "symlink":
                        installer.symlink_to(target)
                    elif case == "hardlink":
                        installer.hardlink_to(target)

                def git(root, *args):
                    if args == ("rev-parse", "HEAD"):
                        return (pair.REFERENCE_SHA if root == roots[0] else "a" * 40).encode()
                    if args[0] == "status":
                        return b" M scripts/install.sh" if case == "dirty" else b""
                    if args[0] == "rev-parse":
                        return pair.REFERENCE_SHA.encode()
                    self.assertEqual(args[0], "show")
                    return original[args[1].split(":", 1)[1]]

                with mock.patch.object(pair, "git", side_effect=git), \
                        mock.patch.object(pair, "CANDIDATE_INSTALLER_SHA256", pair.sha(revised)):
                    if case in ("original", "approved", "post-run-drift"):
                        self.assertEqual(pair.preflight(*roots, "a" * 40), roots)
                        if case == "post-run-drift":
                            for root in roots:
                                for name in (*pair.EXECUTABLES, "scripts/install.sh"):
                                    path = root / name
                                    path.parent.mkdir(parents=True, exist_ok=True)
                                    if not path.exists():
                                        path.write_bytes(name.encode())
                                    path.chmod(0o755)
                            output = pathlib.Path(tmp) / "reports"
                            output.mkdir()
                            pair.write_json(output / "paired-identities.json",
                                            pair.identities(roots, "a" * 40))
                            pair.unchanged(roots, "a" * 40, output)
                            installer.write_bytes(original["scripts/install.sh"])
                            self.assertEqual(pair.preflight(*roots, "a" * 40), roots)
                            with self.assertRaisesRegex(ValueError, "identities changed"):
                                pair.unchanged(roots, "a" * 40, output)
                    elif case == "missing":
                        with self.assertRaises(FileNotFoundError):
                            pair.preflight(*roots, "a" * 40)
                    else:
                        expected = {
                            "unknown": "candidate installer is not a reviewed revision",
                            "reference-approved": "fixed launcher/installer changed",
                            "symlink": "symlink forbidden",
                            "hardlink": "not an unaliased regular file",
                            "dirty": "tracked source is dirty",
                        }[case]
                        with self.assertRaisesRegex(ValueError, expected):
                            pair.preflight(*roots, "a" * 40)

    def test_paired_setup_uses_reference_toolchain_and_unflagged_builds(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        def check(text):
            # Anchor to the actual two-space job, never workflow_call.inputs.scale.
            job = re.split(r"(?m)^  scale:\s*$", text)[1]
            job = re.split(r"(?m)^  [a-zA-Z][a-zA-Z0-9_-]*:\s*$", job)[0]
            self.assertRegex(job, r"(?m)^    runs-on: ubuntu-24\.04$")
            setup = job.split("- name: Install the verified pinned Bend toolchain", 1)[1]
            setup = setup.split("      - name:", 1)[0]
            shell = setup.split("        run: |\n", 1)[1]
            script = "\n".join(line[10:] for line in shell.splitlines())
            for mode, expected in (("false", "reference"), ("true", "candidate")):
                with tempfile.TemporaryDirectory() as tmp:
                    # Execute control flow but intercept installer execution.
                    stub = 'sh() { printf "%s\\n" "$*"; };\n'
                    result = subprocess.run(["bash", "-eu", "-c", stub + script],
                        env={**os.environ, "RECORD_SCALE": mode,
                             "GITHUB_PATH": str(pathlib.Path(tmp) / "path")},
                        text=True, capture_output=True, timeout=2)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.splitlines(),
                                     [expected + "/scripts/install-bend.sh"])
            self.assertEqual(job.count("run: reference/scripts/install.sh\n"), 1)
            self.assertEqual(job.count("run: candidate/scripts/install.sh\n"), 1)
        check(workflow)
        actual_job = workflow.index("\n  scale:\n")
        for mutation in (workflow[:actual_job] + workflow[actual_job:].replace(
                            "runs-on: ubuntu-24.04", "runs-on: ubuntu-24.04-arm", 1),
                         workflow.replace("sh reference/scripts/install-bend.sh",
                            "sh reference/scripts/install-bend.sh\n            sh candidate/scripts/install-bend.sh"),
                         workflow.replace("run: candidate/scripts/install.sh\n",
                            "run: candidate/scripts/install.sh --install-bend\n")):
            with self.assertRaises(AssertionError):
                check(mutation)

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



class ManagedPairTests(unittest.TestCase):
    MEMBERS = ("mailbend-core", "mailbend-tls", "mailbend-attach",
               "mailbend-typesafe", "mailbend-stdio")

    def test_managed_source_tuple_is_literal_and_path_ordered(self):
        self.assertEqual(pair.MANAGED_SCRIPT_PATHS,
                         ("scripts/install.sh", "scripts/mailbend", "scripts/install-layout.sh"))
        self.assertEqual(pair.MANAGED_SCRIPT_TUPLE, (
            "1e6021a670a6d26f2a68a27cd748c1b63238e816dd1dbcf677ba6e9d3b934326",
            "90d6cbca18d2ed0e24883a7417225b98657dd023fee8afe4686ba9c9fecb6aac",
            "d2414f2f66c1a297d1d4330056d86f13a8456ce3053017d3c2209728593fd17f"))

    def roots(self, parent, managed=True):
        roots = tuple(parent / side for side in ("reference", "candidate"))
        original = historical_scripts()
        for root in roots:
            for name in (*pair.PINNED, *original):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(original[name] if name in original else (ROOT / name).read_bytes())
                path.chmod(0o755 if name.startswith("scripts/") else 0o644)
            (root / "bin").mkdir()
            for name in self.MEMBERS:
                path = root / "bin" / name
                path.write_bytes(("#!/bin/sh\necho original-" + name + "\n").encode())
                path.chmod(0o755)
        for name in pair.MANAGED_SCRIPT_PATHS:
            path = roots[1] / name
            path.write_bytes((ROOT / name).read_bytes())
            path.chmod(0o644 if name.endswith("install-layout.sh") else 0o755)
        if managed:
            shutil.rmtree(roots[1] / "bin")
            self.generation(roots[1], "A")
        def git(root, *args):
            if args == ("rev-parse", "HEAD"):
                return (pair.REFERENCE_SHA if root == roots[0] else "a" * 40).encode()
            if args[0] == "status":
                return b""
            if args[0] == "rev-parse":
                return pair.REFERENCE_SHA.encode()
            return original[args[1].split(":", 1)[1]]
        return roots, git

    def generation(self, root, letter, previous="none"):
        identifier = "g." + letter * 12
        meta = root / ".mailbend-install"
        directory = meta / "generations" / identifier
        directory.mkdir(parents=True)
        manifest = "mailbend-generation-v1\ngeneration=" + identifier + "\n"
        for name in self.MEMBERS:
            data = ("#!/bin/sh\necho " + letter + "-" + name + "\n").encode()
            (directory / name).write_bytes(data)
            (directory / name).chmod(0o755)
            manifest += f"{name} {pair.sha(data)} 0755\n"
        (directory / "MANIFEST").write_text(manifest)
        state_id = "s." + letter * 12
        state = meta / "states" / state_id
        state.mkdir(parents=True)
        (state / "FORMAT").write_text("mailbend-install-state-v1\nkind=install\n"
                                      f"active={identifier}\nprevious={previous}\n")
        (state / "active").symlink_to("../../generations/" + identifier)
        if previous != "none":
            (state / "previous").symlink_to("../../generations/" + previous)
        new = meta / "fixture-selector"
        new.symlink_to("states/" + state_id)
        new.replace(meta / "current")
        for name, role in (("bin", "active"), ("bin.prev", "previous")):
            if not (root / name).is_symlink():
                (root / name).symlink_to(".mailbend-install/current/" + role)
        return directory, state

    def test_actual_managed_layout_and_records_are_captured(self):
        with tempfile.TemporaryDirectory() as directory:
            roots, git = self.roots(pathlib.Path(directory))
            with mock.patch.object(pair, "git", side_effect=git):
                self.assertEqual(pair.preflight(*roots, "a" * 40), roots)
                result = pair.identities(roots, "a" * 40)
            candidate = result["checkouts"]["candidate"]
            self.assertEqual(candidate["installation"]["generation"], "g.AAAAAAAAAAAA")
            self.assertIn("scripts/install-layout.sh", candidate["files"])
            self.assertEqual(candidate["installation"]["records"][
                ".mailbend-install/states/s.AAAAAAAAAAAA/FORMAT"]["bytes"],
                "mailbend-install-state-v1\nkind=install\nactive=g.AAAAAAAAAAAA\nprevious=none\n")
            for name in self.MEMBERS:
                self.assertIn("/generations/g.AAAAAAAAAAAA/" + name,
                              candidate["files"]["bin/" + name]["physical_path"])

    def test_layout_matrix_refuses_flat_new_and_managed_historical_or_reference(self):
        for case in ("new-flat", "historical-managed", "reference-managed"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                roots, git = self.roots(pathlib.Path(directory), managed=case != "new-flat")
                if case == "historical-managed":
                    for name, data in historical_scripts().items():
                        (roots[1] / name).write_bytes(data)
                elif case == "reference-managed":
                    shutil.rmtree(roots[0] / "bin")
                    self.generation(roots[0], "R")
                with mock.patch.object(pair, "git", side_effect=git):
                    pair.preflight(*roots, "a" * 40)
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        pair.identities(roots, "a" * 40)

    def test_managed_negative_layout_and_record_controls(self):
        cases = ("member-link", "hardlink", "external-bin", "ancestor-link", "missing",
                 "version", "field", "reordered", "duplicate", "oversized", "wrong-generation",
                 "manifest-hash", "mode", "missing-previous", "current-traversal")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                parent = pathlib.Path(directory)
                roots, git = self.roots(parent)
                root = roots[1]
                meta = root / ".mailbend-install"
                generation = meta / "generations/g.AAAAAAAAAAAA"
                state = meta / "states/s.AAAAAAAAAAAA"
                member = generation / "mailbend-core"
                record = state / "FORMAT"
                if case in ("member-link", "hardlink", "missing"):
                    member.unlink()
                    if case == "member-link":
                        member.symlink_to(roots[0] / "bin/mailbend-core")
                    elif case == "hardlink":
                        os.link(roots[0] / "bin/mailbend-core", member)
                elif case == "external-bin":
                    (root / "bin").unlink()
                    (root / "bin").symlink_to(generation)
                elif case == "ancestor-link":
                    moved = parent / "moved-generations"
                    (meta / "generations").rename(moved)
                    (meta / "generations").symlink_to(moved)
                elif case in ("version", "field", "reordered", "duplicate", "oversized"):
                    data = record.read_bytes()
                    data = {"version": data.replace(b"state-v1", b"state-v2"),
                            "field": data + b"extra=bad\n",
                            "reordered": b"\n".join(data.split(b"\n")[1:2] + data.split(b"\n")[:1]
                                                     + data.split(b"\n")[2:]),
                            "duplicate": data + b"previous=none\n",
                            "oversized": b"x" * 257}[case]
                    record.write_bytes(data)
                elif case == "wrong-generation":
                    manifest = generation / "MANIFEST"
                    manifest.write_bytes(manifest.read_bytes().replace(b"g.AAAAAAAAAAAA", b"g.BBBBBBBBBBBB"))
                elif case == "manifest-hash":
                    member.write_bytes(b"#!/bin/sh\necho changed\n")
                elif case == "mode":
                    member.chmod(0o775)
                elif case == "missing-previous":
                    record.write_bytes(record.read_bytes().replace(b"previous=none", b"previous=g.BBBBBBBBBBBB"))
                    (state / "previous").symlink_to("../../generations/g.BBBBBBBBBBBB")
                else:
                    (meta / "current").unlink()
                    (meta / "current").symlink_to("states/../states/s.AAAAAAAAAAAA")
                with mock.patch.object(pair, "git", side_effect=git):
                    if case == "missing-previous":
                        with self.assertRaises(FileNotFoundError):
                            pair.identities(roots, "a" * 40)
                    else:
                        reason = {"member-link": "object type", "hardlink": "unaliased regular",
                                  "external-bin": "link target", "ancestor-link": "object type",
                                  "missing": "generation inventory", "version": "state record grammar",
                                  "field": "state record grammar", "reordered": "state record grammar",
                                  "duplicate": "state record grammar", "oversized": "oversized or empty",
                                  "wrong-generation": "manifest record grammar", "manifest-hash": "manifest mismatch",
                                  "mode": "object mode", "current-traversal": "complete normal state"}[case]
                        with self.assertRaisesRegex(ValueError, reason):
                            pair.identities(roots, "a" * 40)

    def test_identity_phase_rejects_selector_change_during_opened_member_read(self):
        with tempfile.TemporaryDirectory() as directory:
            roots, git = self.roots(pathlib.Path(directory))
            meta = roots[1] / ".mailbend-install"
            wanted = (roots[1] / "bin/mailbend-core").stat().st_ino
            read, fired = os.read, []
            def moving_read(fd, size):
                data = read(fd, size)
                if not fired and os.fstat(fd).st_ino == wanted:
                    fired.append(True)
                    new = meta / "replacement"
                    new.symlink_to(os.readlink(meta / "current"))
                    new.replace(meta / "current")
                return data
            with mock.patch.object(pair, "git", side_effect=git), mock.patch.object(os, "read", side_effect=moving_read):
                with self.assertRaisesRegex(ValueError, "snapshot changed during capture"):
                    pair.identities(roots, "a" * 40)
            self.assertEqual(fired, [True], "the drift control must actually intercept a member read")

    def test_saved_identity_refuses_identical_target_replacement_and_approved_upgrade(self):
        for change in ("identical-target", "upgrade", "shared-script"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                parent = pathlib.Path(directory)
                roots, git = self.roots(parent)
                output = parent / "output"
                output.mkdir()
                with mock.patch.object(pair, "git", side_effect=git):
                    pair.write_json(output / "paired-identities.json", pair.identities(roots, "a" * 40))
                    if change == "upgrade":
                        self.generation(roots[1], "B", "g.AAAAAAAAAAAA")
                    elif change == "shared-script":
                        with (roots[1] / "scripts/install-layout.sh").open("ab") as handle:
                            handle.write(b"\n# drift\n")
                    else:
                        meta = roots[1] / ".mailbend-install"
                        replacement = meta / "replacement"
                        replacement.symlink_to(os.readlink(meta / "current"))
                        replacement.replace(meta / "current")
                    with self.assertRaises(ValueError):
                        pair.unchanged(roots, "a" * 40, output)

    def test_root_and_compatible_bin_locks_fail_fast_and_release(self):
        import fcntl
        for selected in ("root", "bin"):
            with self.subTest(lock=selected), tempfile.TemporaryDirectory() as directory:
                roots, git = self.roots(pathlib.Path(directory))
                path = roots[0] if selected == "root" else roots[0] / "bin"
                held = os.open(path, os.O_RDONLY)
                try:
                    fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    with mock.patch.object(pair, "git", side_effect=git):
                        with self.assertRaisesRegex(ValueError, "lock is busy"):
                            pair.identities(roots, "a" * 40)
                finally:
                    os.close(held)
                with mock.patch.object(pair, "git", side_effect=git):
                    pair.identities(roots, "a" * 40)


if __name__ == "__main__":
    os.umask(0o022)
    unittest.main()
