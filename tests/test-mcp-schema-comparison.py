#!/usr/bin/env python3
"""Lifecycle controls for the hosted comparison, without Bend or mail."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("comparison", Path(__file__).with_name("compare-mcp-schema.py"))
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


class ComparisonControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        comparison.enable_subreaper()

    def test_partial_startup_line_is_deadline_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            launcher = root / "scripts/mailbend"
            launcher.write_text('#!/usr/bin/env python3\nimport sys,time\nsys.stdout.write("{"); sys.stdout.flush(); time.sleep(30)\n')
            launcher.chmod(0o755)
            real_select = comparison.select.select
            calls = 0
            def readiness(*args):
                nonlocal calls
                calls += 1
                return real_select(*args) if calls == 1 else ([], [], [])
            with patch.object(comparison.select, "select", side_effect=readiness):
                with self.assertRaisesRegex(AssertionError, "startup timeout"):
                    comparison.startup(root, comparison.clean_env(root))
            self.assertEqual(calls, 2)

    def test_startup_rejects_malformed_and_oversized_reply(self):
        for payload in ('"invalid\\n"', '"x" * (1024 * 1024 + 1)'):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "scripts").mkdir()
                launcher = root / "scripts/mailbend"
                launcher.write_text('#!/usr/bin/env python3\nimport sys,time\nsys.stdout.write(' + payload + '); sys.stdout.flush(); time.sleep(30)\n')
                launcher.chmod(0o755)
                with self.assertRaises((ValueError, AssertionError)):
                    comparison.startup(root, comparison.clean_env(root))

    def test_apparatus_mismatch_is_not_comparable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tests/fixtures").mkdir(parents=True)
            for path in ("tests/fixtures/mailbox.json", "tests/fake_mail_server.py", "tests/gen-test-certs.sh"):
                (root / path).write_text("fixture")
            self.assertEqual(len(comparison.check_apparatus([root], root)), 3)
            other = root / "other"
            (other / "tests/fixtures").mkdir(parents=True)
            for path in ("tests/fixtures/mailbox.json", "tests/fake_mail_server.py", "tests/gen-test-certs.sh"):
                (other / path).write_text("changed")
            with self.assertRaisesRegex(AssertionError, "apparatus differs"):
                comparison.check_apparatus([other], root)

    def test_candidate_failures_remain_blocking(self):
        rows = [{"side": side, "exit_code": 0} for side in ("reference", "candidate", "candidate", "reference")]
        self.assertEqual(comparison.comparison_failed(rows), 0)
        rows[0]["exit_code"] = 1
        self.assertEqual(comparison.comparison_failed(rows), 0)
        rows[2]["exit_code"] = 1
        self.assertEqual(comparison.comparison_failed(rows), 1)
        with self.assertRaisesRegex(AssertionError, "incomplete comparison"):
            comparison.comparison_failed(rows[:-1])

    def test_outer_timeout_reaps_separate_child_session(self):
        for exit_early in (False, True):
            with self.subTest(exit_early=exit_early):
                code = ('import subprocess,sys,time\n'
                        'child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"],start_new_session=True)\n'
                        'print(child.pid,flush=True)\n' + ('' if exit_early else 'time.sleep(60)\n'))
                proc = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE,
                                        text=True, start_new_session=True)
                child = int(proc.stdout.readline())
                try:
                    if exit_early:
                        proc.wait(timeout=5)
                    comparison.reap_timeout(proc)
                    identity = comparison.process_identity(child)
                    self.assertTrue(identity is None or identity[1] in ("Z", "X"))
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait()
                    identity = comparison.process_identity(child)
                    if identity is not None and identity[1] not in ("Z", "X"):
                        os.kill(child, 9)
                    proc.stdout.close()


if __name__ == "__main__":
    unittest.main()
