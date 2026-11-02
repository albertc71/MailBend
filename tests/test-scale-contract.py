#!/usr/bin/env python3
"""Fast controls for scale measurement, comparison and synthetic input shape."""
import importlib.util
import json
import os
import signal
import subprocess
import pathlib
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock

from scale_baseline import select_baseline
from scale_fixtures import SCENARIOS, Scenario, fixture, sized_message

SPEC = importlib.util.spec_from_file_location("scale", pathlib.Path(__file__).with_name("test-scale.py"))
scale = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scale)


def sample(count=1):
    return {"status": "passed", "wall_seconds": 1.0, "peak_rss_kib": 1000,
            "imap_logins": 2, "exit_code": 0, "timed_out": False,
            "work": {"fixture_count": count, "body_bytes_fetched": 0,
                     "smtp_messages": 0, "typesafe_requests": 0}}


def report():
    return {"status": "measured", "profile": {"runner": "synthetic-test"},
            "scenarios": {s.name: scale.summarize([sample(s.count) for _ in range(5)]) for s in SCENARIOS}}


class Contract(unittest.TestCase):
    def test_cancellation_cleans_servers_and_measured_group(self):
        harness = r"""
import importlib.util, pathlib, sys, time
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
spec = importlib.util.spec_from_file_location("scale", sys.argv[1])
scale = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scale)
work = pathlib.Path(sys.argv[2])
servers = []
try:
    with scale.RunControl(time.monotonic() + 10) as control:
        try:
            for index in range(2):
                server = scale.Server([sys.executable, "-c", "import time;print('READY imap=1',flush=True);time.sleep(30)"],
                                      scale.clean_env(work), work, str(index), 2, control)
                servers.append(server)
            (work / "servers").write_text(" ".join(str(s.proc.pid) for s in servers))
            command = [sys.executable, "-c", "import os,pathlib,time;pathlib.Path('child').write_text(str(os.getpgrp()));time.sleep(30)"]
            # The child gets an absolute readiness path, independent of cwd.
            command[2] = command[2].replace("'child'", repr(str(work / "child")))
            scale.measure(command, scale.clean_env(work), work, 10, control)
        finally:
            for server in reversed(servers):
                server.stop()
except scale.Cancelled:
    sys.exit(23)
sys.exit(24)
"""
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig), tempfile.TemporaryDirectory() as directory:
                work = pathlib.Path(directory)
                proc = subprocess.Popen([sys.executable, "-c", harness,
                                         str(pathlib.Path(scale.__file__)), str(work)],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                groups = []
                try:
                    deadline = time.monotonic() + 8
                    while not (work / "child").exists() or not (work / "child").read_text():
                        if proc.poll() is not None or time.monotonic() >= deadline:
                            self.fail("cancellation harness did not start its child")
                        time.sleep(0.01)
                    groups = list(map(int, (work / "servers").read_text().split()))
                    groups.append(int((work / "child").read_text()))
                    proc.send_signal(sig)
                    _, errors = proc.communicate(timeout=5)
                    self.assertEqual(proc.returncode, 23, errors.decode())
                    for group in groups:
                        self.assert_group_stopped(group)
                finally:
                    if proc.poll() is None:
                        proc.terminate()
                        try:
                            proc.communicate(timeout=5)
                        except subprocess.TimeoutExpired:
                            proc.kill()
                    proc.communicate(timeout=5)
                    if (work / "servers").exists():
                        groups.extend(map(int, (work / "servers").read_text().split()))
                    if (work / "child").exists() and (work / "child").read_text():
                        groups.append(int((work / "child").read_text()))
                    for group in set(groups):
                        try:
                            os.killpg(group, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def assert_group_stopped(self, group):
        # Orphaned zombies can await init; no live process may remain in the group.
        for entry in pathlib.Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                text = (entry / "stat").read_text()
                fields = text[text.rindex(")") + 2:].split()
            except (OSError, ValueError):
                continue
            self.assertFalse(int(fields[2]) == group and fields[0] != "Z",
                             f"live process {entry.name} remains in group {group}")

    def test_cancel_during_server_spawn_is_deferred_until_owned(self):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            spawned = []
            popen = subprocess.Popen
            def spawn(*args, **kwargs):
                proc = popen(*args, **kwargs)
                spawned.append(proc)
                signal.raise_signal(signal.SIGTERM)
                return proc
            try:
                with scale.RunControl(time.monotonic() + 5) as control:
                    with mock.patch.object(scale.subprocess, "Popen", side_effect=spawn):
                        with self.assertRaises(scale.Cancelled):
                            scale.Server([sys.executable, "-c", "import time;time.sleep(10)"],
                                         scale.clean_env(work), work, "spawn", 2, control)
                self.assertEqual(len(spawned), 1)
                self.assertIsNotNone(spawned[0].returncode)
                self.assert_group_stopped(spawned[0].pid)
            finally:
                for proc in spawned:
                    scale.kill_group(proc)

    def test_second_signal_does_not_interrupt_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            with scale.RunControl(time.monotonic() + 5) as control:
                servers = []
                try:
                    for i in range(2):
                        server = scale.Server([sys.executable, "-c", "import time;print('READY imap=1',flush=True);time.sleep(10)"],
                                              scale.clean_env(work), work, str(i), 2, control)
                        servers.append(server)
                    signal.raise_signal(signal.SIGTERM)
                    with self.assertRaises(scale.Cancelled):
                        control.check()
                finally:
                    for server in servers:
                        signal.raise_signal(signal.SIGHUP)
                        server.stop()
            for server in servers:
                self.assertIsNotNone(server.proc.returncode)
                self.assert_group_stopped(server.proc.pid)

    def test_suite_deadline_cleans_partial_readiness(self):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            started = time.monotonic()
            with scale.RunControl(started + 0.05) as control:
                with self.assertRaisesRegex(TimeoutError, "suite deadline"):
                    scale.Server([sys.executable, "-c", "import sys,time;sys.stdout.write('READY');sys.stdout.flush();time.sleep(10)"],
                                 scale.clean_env(work), work, "partial-deadline", 5, control)
            self.assertLess(time.monotonic() - started, 2)

    def test_malformed_result_records_failure_and_runs_next_scenario(self):
        for failure in (KeyError("total"), TypeError("wrong result shape"),
                        AttributeError("wrong nested result shape")):
            with self.subTest(failure=type(failure)), tempfile.TemporaryDirectory() as directory:
                work = pathlib.Path(directory)
                seen = []
                def run(scenario, sample_work, certs, control):
                    seen.append(scenario.name)
                    self.assertEqual(sample_work.parent.parent, work)
                    if len(seen) == 1:
                        raise failure
                    return sample(scenario.count)
                with mock.patch.multiple(scale, SCENARIOS=SCENARIOS[:2], REPEATS=1,
                                         profile=lambda: {}, digest=lambda _: "synthetic",
                                         certificates=lambda root, env, control: root,
                                         run_sample=run), \
                     mock.patch.object(scale.os, "access", return_value=True), \
                     mock.patch.object(scale.subprocess, "check_output", return_value="synthetic"), \
                     mock.patch.dict(os.environ, {"MAILBEND_TEST_TMPDIR": str(work)}), \
                     mock.patch.object(sys, "argv", ["test-scale.py", "--record", "--output", str(work / "result.json")]):
                    self.assertEqual(scale.main(), 1)
                result = json.loads((work / "result.json").read_text())
                self.assertEqual(seen, [s.name for s in SCENARIOS[:2]])
                self.assertEqual(result["scenarios"][seen[0]]["samples"][0]["reason"], type(failure).__name__)
                self.assertEqual(result["scenarios"][seen[1]]["status"], "passed")
                self.assertEqual(result["status"], "incomplete")

    def test_non_object_tool_result_is_rejected(self):
        for result in (None, [], "bad", 5, True):
            with self.subTest(result=result), self.assertRaisesRegex(ValueError, "not an object"):
                scale.verify(SCENARIOS[0], {}, result, [], {}, [])

    def test_profile_tracks_fixture_dependencies_and_python(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "tests").mkdir()
            names = ("scale_fixtures.py", "image_fixtures.py", "fake_mail_server.py", "fake_typesafe.py")
            for name in names:
                (root / "tests" / name).write_text(name)
            timer = root / "time"
            timer.write_text("synthetic timer")
            with mock.patch.object(scale, "ROOT", root), \
                    mock.patch.object(scale.shutil, "which", return_value=str(timer)), \
                    mock.patch.object(scale.subprocess, "check_output", return_value="synthetic version"):
                original = scale.profile()
                self.assertEqual(original["python_version"], scale.platform.python_version())
                self.assertEqual(original["python_implementation"], scale.platform.python_implementation())
                before = report()
                before["profile"] = original
                for name in names:
                    path = root / "tests" / name
                    path.write_text(name + " changed")
                    after = report()
                    after["profile"] = scale.profile()
                    self.assertIn("not comparable", scale.compare(before, after)[0], name)
                    path.write_text(name)
                with mock.patch.object(scale.platform, "python_version", return_value="different Python"):
                    after = report()
                    after["profile"] = scale.profile()
                    self.assertIn("not comparable", scale.compare(before, after)[0])

    def test_comparison_filter_covers_measured_dependencies(self):
        workflow = (scale.ROOT / ".github/workflows/scale-compare.yml").read_text()
        paths = {line.removeprefix("      - ") for line in workflow.splitlines()
                 if line.startswith("      - ")}
        self.assertEqual(paths, {
            "tests/test-scale.py", "tests/scale_fixtures.py", "tests/image_fixtures.py",
            "tests/fake_mail_server.py", "tests/fake_typesafe.py", "tests/scale-baseline.json",
            ".github/workflows/scale-compare.yml", ".github/workflows/ci.yml",
            "tests/scale-baseline-epyc7763.json", "tests/scale_baseline.py"})

    def test_baseline_selection_preserves_full_profile_gate(self):
        for cpu in ("AMD EPYC 9V45 96-Core Processor",):
            with self.subTest(cpu=cpu):
                baseline = json.loads(select_baseline(cpu).read_text())
                self.assertEqual(baseline["profile"]["cpu"], cpu)
                self.assertEqual(scale.compare(baseline, baseline), [])
                changed = json.loads(json.dumps(baseline))
                changed["profile"]["python_version"] = "different"
                self.assertEqual(scale.compare(baseline, changed), [
                    "runner/toolchain profile differs; measurements are not comparable"])
        for cpu in ("unknown", "", "AMD EPYC 7763", "AMD EPYC 7763 64-Core Processor",
                    "INTEL(R) XEON(R) PLATINUM 8573C"):
            with self.subTest(cpu=cpu), self.assertRaises(ValueError):
                select_baseline(cpu)

    def test_unknown_cpu_workflow_captures_evidence_but_cannot_pass(self):
        workflow = (scale.ROOT / ".github/workflows/ci.yml").read_text()
        step = workflow.split("      - name: Measure only local synthetic workloads\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1].split("      - name:", 1)[0])
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            python = root / "python3"
            python.write_text("#!/bin/sh\n"
                'case "$1" in\n'
                '  tests/scale_baseline.py) [ "$UNKNOWN_CPU" = yes ] && exit 1; echo reviewed.json ;;\n'
                '  tests/test-scale.py) printf "%s\\n" "$*" > "$CALL_LOG" ;;\n'
                'esac\n')
            python.chmod(0o755)
            for unknown, expected in (("yes", 1), ("no", 0)):
                with self.subTest(unknown=unknown):
                    env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"],
                               RECORD_SCALE="false", UNKNOWN_CPU=unknown, CALL_LOG=str(root / "call"))
                    result = subprocess.run(["bash", "-e", "-c", script], cwd=root, env=env,
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    call = (root / "call").read_text()
                    self.assertIn("--output scale-results.json", call)
                    self.assertNotIn("--record", call)
                    self.assertEqual("--baseline reviewed.json" in call, unknown == "no")

    def test_forward_command_guards_allow_only_sent_append(self):
        safe = ['A1 EXAMINE "INBOX"', 'A2 UID FETCH 1 (BODY.PEEK[])',
                'A3 APPEND "Sent" (\\Seen) {24}']
        scale.verify_commands("forward", safe)
        for line in ('A1 SELECT "INBOX"', 'A2 EXPUNGE', 'A3 UID EXPUNGE 1',
                     'A4 UID FETCH 1 (BODY[])', 'A5 UID STORE 1 +FLAGS (\\Seen)',
                     'A6 APPEND "INBOX" (\\Seen) {24}', 'A7 CREATE "Other"',
                     'a8 select "INBOX"'):
            with self.subTest(command=line), self.assertRaises(ValueError):
                scale.verify(SCENARIOS[4], {}, {}, [{"proto": "imap", "line": line}], {}, [])
        with self.assertRaises(ValueError):
            scale.verify_commands("read", safe)

    def test_normal_exit_stops_remaining_group_members(self):
        for exit_code in (0, 17):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as directory:
                work = pathlib.Path(directory)
                record = work / "orphan.json"
                command = ("import json,os,pathlib,subprocess,sys; "
                           "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)']); "
                           f"pathlib.Path({str(record)!r}).write_text(json.dumps([child.pid,os.getpgrp()])); "
                           f"sys.exit({exit_code})")
                try:
                    result = scale.measure([sys.executable, "-c", command], scale.clean_env(work), work, 5)
                    self.assertEqual(result["exit_code"], exit_code)
                    self.assertFalse(result["timed_out"])
                    child, group = json.loads(record.read_text())
                    self.assertNotEqual(group, os.getpgrp())
                    deadline = time.monotonic() + 2
                    while True:
                        try:
                            self.assert_group_stopped(group)
                            break
                        except AssertionError:
                            if time.monotonic() >= deadline:
                                raise
                            time.sleep(0.01)
                finally:
                    if record.exists():
                        _, group = json.loads(record.read_text())
                        if group != os.getpgrp():
                            try:
                                os.killpg(group, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                            deadline = time.monotonic() + 2
                            while True:
                                try:
                                    self.assert_group_stopped(group)
                                    break
                                except AssertionError:
                                    if time.monotonic() >= deadline:
                                        raise
                                    time.sleep(0.01)

    def test_equal_baseline(self):
        self.assertEqual(scale.compare(report(), report()), [])

    def test_deliberate_slowdown(self):
        old, new = report(), report()
        row = new["scenarios"][SCENARIOS[0].name]
        for s in row["samples"]:
            s["wall_seconds"] *= 1.26
        new["scenarios"][SCENARIOS[0].name] = scale.summarize(row["samples"])
        self.assertEqual(scale.compare(old, new), ["search-100000: wall_seconds exceeds baseline by more than 25%"])

    def test_exact_threshold(self):
        old, new = report(), report()
        for s in new["scenarios"][SCENARIOS[0].name]["samples"]:
            s["wall_seconds"] *= 1.25
        new["scenarios"][SCENARIOS[0].name] = scale.summarize(new["scenarios"][SCENARIOS[0].name]["samples"])
        self.assertEqual(scale.compare(old, new), [])

    def test_other_resource_regressions(self):
        for key in ("peak_rss_kib", "imap_logins"):
            old, new = report(), report()
            for s in new["scenarios"][SCENARIOS[0].name]["samples"]:
                s[key] *= 2
            new["scenarios"][SCENARIOS[0].name] = scale.summarize(new["scenarios"][SCENARIOS[0].name]["samples"])
            self.assertTrue(scale.compare(old, new), key)

    def test_incomplete_never_passes(self):
        for status in ("unmeasured", "incomplete", "failed"):
            bad = report()
            bad["status"] = status
            self.assertTrue(scale.compare(bad, report()))
            self.assertTrue(scale.compare(report(), bad))

    def test_profile_mismatch(self):
        new = report()
        new["profile"]["runner"] = "another-host"
        self.assertIn("not comparable", scale.compare(report(), new)[0])

    def test_missing_scenario(self):
        new = report()
        del new["scenarios"][SCENARIOS[0].name]
        self.assertEqual(scale.compare(report(), new), ["scenario coverage differs"])

    def test_forged_summary(self):
        new = report()
        new["scenarios"][SCENARIOS[0].name]["metrics"]["wall_seconds"]["median"] = 0.1
        self.assertTrue(scale.compare(report(), new))

    def test_invalid_off_median_sample(self):
        for value in (float("nan"), float("inf"), -1, 0, True, "1", None):
            new = report()
            new["scenarios"][SCENARIOS[0].name]["samples"][0]["wall_seconds"] = value
            self.assertTrue(scale.compare(report(), new), str(value))

    def test_failure_is_not_speed(self):
        for key, value in (("status", "failed"), ("exit_code", 1), ("timed_out", True)):
            samples = [sample() for _ in range(5)]
            samples[0][key] = value
            self.assertEqual(scale.summarize(samples)["status"], "incomplete")
        self.assertEqual(scale.summarize([sample()])["status"], "incomplete")

    def test_wrong_work_is_not_speed(self):
        new = report()
        for s in new["scenarios"][SCENARIOS[0].name]["samples"]:
            s["work"]["fixture_count"] = 10
        self.assertTrue(scale.compare(report(), new))

    def test_malformed_shapes_refused(self):
        for value in (None, [], "bad", 1):
            self.assertTrue(scale.compare(value, report()))
            bad = report()
            bad["scenarios"] = value
            self.assertTrue(scale.compare(report(), bad))
            bad = report()
            bad["scenarios"][SCENARIOS[0].name] = value
            self.assertTrue(scale.compare(report(), bad))

    def test_exact_bytes(self):
        for size in (1024, 4096, 8192):
            raw = sized_message(size)["raw"]
            self.assertEqual(len(raw.encode("ascii")), size)
            self.assertTrue(raw.endswith("SCALE-END\r\n"))
            self.assertLessEqual(max(map(len, raw.split("\r\n"))), 998)

    def test_fixed_scale_sizes(self):
        self.assertEqual([s.count for s in SCENARIOS], [100000, 1000, 5000, 16 * 1024 ** 2,
                                                       25 * 1024 ** 2, 1000, 50])

    def test_thread_topology(self):
        data = fixture(Scenario("test", "mail_get_thread", {"uid": 1}, 10, "thread"))
        raws = [m["raw"] for m in data["mailboxes"]["INBOX"]["messages"]]
        ids = [raw.split("Message-ID: ")[1].split("\r\n")[0] for raw in raws]
        self.assertEqual(len(set(ids)), 10)
        self.assertTrue(all(f"References: {ids[0]}\r\n" in raw for raw in raws[1:]))

    def test_clean_environment(self):
        env = scale.clean_env(pathlib.Path("/tmp/synthetic"))
        self.assertEqual(set(env), {"PATH", "HOME", "LANG", "LC_ALL", "BEND_NO_TELEMETRY"})

    def test_rss_is_per_child(self):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            env = scale.clean_env(work)
            high = scale.measure([sys.executable, "-c", "x=bytearray(64*1024*1024); print(len(x))"], env, work, 5)
            low = scale.measure([sys.executable, "-c", "print('small')"], env, work, 5)
            self.assertEqual((high["exit_code"], low["exit_code"]), (0, 0))
            self.assertGreater(high["peak_rss_kib"], low["peak_rss_kib"] + 32000)

    def test_fixture_parent_is_not_measured(self):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            dirty = bytearray(96 * 1024 * 1024)
            dirty[::4096] = b"x" * (len(dirty) // 4096)
            result = scale.measure([sys.executable, "-c", "print('small')"],
                                   scale.clean_env(work), work, 5)
            self.assertEqual(result["exit_code"], 0)
            self.assertLess(result["peak_rss_kib"], 48000)

    def test_timeout_is_a_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            result = scale.measure([sys.executable, "-c", "import time; time.sleep(5)"],
                                   scale.clean_env(work), work, 0.05)
            self.assertTrue(result["timed_out"])
            self.assertNotEqual(result["exit_code"], 0)

    def test_partial_readiness_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            start = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, "startup timed out"):
                scale.Server([sys.executable, "-c", "import sys,time;sys.stdout.write('READY');sys.stdout.flush();time.sleep(5)"],
                             scale.clean_env(work), work, "partial", 0.05)
            self.assertLess(time.monotonic() - start, 2)


if __name__ == "__main__":
    unittest.main()
