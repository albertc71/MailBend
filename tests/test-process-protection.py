#!/usr/bin/env python3
"""Exercise helper-local dump controls without changing the host core pattern."""

import errno
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from fake_typesafe import environ_names, protected_environment

ROOT = Path(__file__).resolve().parents[1]


class ProcessProtection(unittest.TestCase):
    def check_helper(self, name, mode, env):
        with tempfile.TemporaryDirectory(prefix="mailbend-no-dumps-") as scratch:
            path = Path(scratch)
            key = path / "key"
            key.write_text("synthetic-typesafe-key")
            key.chmod(0o600)
            helper = subprocess.Popen(
                [str(ROOT / "bin" / name), mode],
                env={"MAILBEND_TYPESAFE_KEY_FILE": str(key), **env}, cwd=path,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            try:
                deadline = time.monotonic() + 5
                while not protected_environment(helper.pid):
                    self.assertIsNone(helper.poll(), "helper exited before protection")
                    self.assertLess(time.monotonic(), deadline, "protection not observed")
                    time.sleep(0.01)
                with self.assertRaises(PermissionError) as denied:
                    Path(f"/proc/{helper.pid}/environ").read_bytes()
                self.assertEqual(denied.exception.errno, errno.EACCES)
                os.kill(helper.pid, signal.SIGQUIT)
                while True:
                    pid, status = os.waitpid(helper.pid, os.WNOHANG)
                    if pid:
                        helper.returncode = os.waitstatus_to_exitcode(status)
                        break
                    self.assertLess(time.monotonic(), deadline, "SIGQUIT did not stop the helper")
                    time.sleep(0.01)
                self.assertTrue(os.WIFSIGNALED(status))
                self.assertEqual(os.WTERMSIG(status), signal.SIGQUIT)
                self.assertFalse(os.WCOREDUMP(status), "kernel reported a core dump")
                self.assertEqual(list(path.iterdir()), [key])
            finally:
                if helper.poll() is None:
                    helper.kill()
                helper.communicate(timeout=5)

    def test_mail_helper(self):
        self.check_helper("mailbend-tls", "imap", {
            "MAILBEND_EMAIL": "user@example.com",
            "MAILBEND_APP_PASSWORD": "synthetic-mail-password",
        })

    def test_typesafe_after_environment_reexecution(self):
        self.check_helper("mailbend-typesafe", "ask", {
            "MAILBEND_EMAIL": "user@example.com",
            "MAILBEND_APP_PASSWORD": "synthetic-mail-password",
            "UNRELATED_SETTING": "must-not-survive-exec",
        })

    def test_launcher_passes_a_zero_core_limit_to_the_core(self):
        with tempfile.TemporaryDirectory(prefix="mailbend-launcher-limit-") as scratch:
            root = Path(scratch)
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            launcher = root / "scripts/mailbend"
            launcher.write_bytes((ROOT / "scripts/mailbend").read_bytes())
            core = root / "bin/mailbend-core"
            core.write_text("#!/bin/sh\nulimit -c\n")
            core.chmod(0o700)
            result = subprocess.run(["sh", str(launcher), "tools"], env={"PATH": os.defpath},
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "0")


class EnvironmentObservation(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="mailbend-proc-observer-")
        self.addCleanup(self.work.cleanup)
        self.proc = Path(self.work.name)
        self.pid = self.proc / "123"
        self.pid.mkdir()
        (self.pid / "cmdline").write_bytes(b"/bin/mailbend-typesafe\0ask\0")
        (self.pid / "environ").write_bytes(b"MAILBEND_TYPESAFE_KEY_FILE=/key\0")

    def test_readable_environment_is_actually_observed(self):
        self.assertEqual(environ_names(self.proc), [{"names": ["MAILBEND_TYPESAFE_KEY_FILE"]}])
        (self.pid / "environ").write_bytes(b"MAILBEND_APP_PASSWORD=synthetic\0")
        self.assertEqual(environ_names(self.proc), [{"names": ["MAILBEND_APP_PASSWORD"]}])

    def test_denied_reads_need_independent_protection_evidence(self):
        read_bytes = Path.read_bytes

        def denied(path):
            if path.name == "environ":
                raise PermissionError(errno.EACCES, "denied")
            return read_bytes(path)

        with patch.object(Path, "read_bytes", denied):
            with patch("fake_typesafe.protected_environment", return_value=False):
                with self.assertRaises(PermissionError):
                    environ_names(self.proc)
            with patch("fake_typesafe.protected_environment", return_value=True):
                self.assertEqual(environ_names(self.proc), [{"non_dumpable": True}])

    def test_protection_evidence_handles_unmapped_kernel_ownership(self):
        (self.pid / "status").write_text("Uid:\t1000\t1000\t1000\t1000\n")
        (self.pid / "limits").write_text("Max core file size        0        0        bytes\n")
        with patch("fake_typesafe.os.geteuid", return_value=1000):
            for owner in (0, 65534):
                with patch.object(Path, "stat", return_value=SimpleNamespace(st_uid=owner)):
                    self.assertTrue(protected_environment(123, self.proc))
            with patch.object(Path, "stat", return_value=SimpleNamespace(st_uid=1000)):
                self.assertFalse(protected_environment(123, self.proc))
            with patch.object(Path, "stat", return_value=SimpleNamespace(st_uid=0)):
                (self.pid / "limits").write_text("Max core file size        0        unlimited        bytes\n")
                self.assertFalse(protected_environment(123, self.proc))
                (self.pid / "limits").write_text("Max core file size        0        0        bytes\n")
                (self.pid / "status").write_text("Uid:\t1001\t1001\t1001\t1001\n")
                self.assertFalse(protected_environment(123, self.proc))

    def test_other_io_errors_do_not_hide_the_helper(self):
        read_bytes = Path.read_bytes

        def failed(path):
            if path.name == "environ":
                raise OSError(errno.EIO, "read failed")
            return read_bytes(path)

        with patch.object(Path, "read_bytes", failed), self.assertRaises(OSError):
            environ_names(self.proc)


if __name__ == "__main__":
    try:
        pattern = Path("/proc/sys/kernel/core_pattern").read_text().strip()
    except OSError as error:
        pattern = f"unavailable ({error.strerror})"
    print(f"Process-local SIGQUIT checks with unchanged core_pattern={pattern!r}")
    unittest.main()
