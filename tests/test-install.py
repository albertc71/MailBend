#!/usr/bin/env python3
import fcntl
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


def executable(path, text):
    path.write_text("#!/bin/sh\n" + text)
    path.chmod(0o755)


NEW_HELPER = b"#!/bin/sh\nexit 0\n"
NEW_CORE = b"#!/bin/sh\necho NEW_CORE\n"
HELPERS = ("mailbend-tls", "mailbend-attach", "mailbend-typesafe", "mailbend-stdio")
TARGETS = HELPERS + ("mailbend-core",)
CORE_BEND = """if [ "$1" = main.bend ]; then
  printf '#!/bin/sh\\necho NEW_CORE\\n' > "$3"
  /bin/chmod +x "$3"
fi
"""


def cargo_writing(broken=None):
    """A cargo that builds every helper, `broken` as one that cannot run."""
    return f"""if [ "$1" = --version ]; then
  echo 'cargo 1.99.0'
  exit 0
fi
/bin/mkdir -p target/release
for name in mailbend-tls mailbend-attach mailbend-typesafe mailbend-stdio; do
  if [ "$name" = "{broken or ''}" ]; then
    printf '#!/bin/sh\\nexit 127\\n' > "target/release/$name"
  else
    printf '#!/bin/sh\\nexit 0\\n' > "target/release/$name"
  fi
  /bin/chmod +x "target/release/$name"
done
"""


class InstallTests(unittest.TestCase):
    def prepare(self, root, clang=False, cargo=None, bend=CORE_BEND):
        tools = root / "tools"
        tools.mkdir()
        (root / "native").mkdir()
        (root / "scripts").mkdir()
        (root / "bin").mkdir()
        shutil.copy2(ROOT / "scripts/install.sh", root / "scripts/install.sh")
        for name in ("dirname", "sed", "mkdir", "cp", "mv", "rm", "sync", "flock"):
            (tools / name).symlink_to(shutil.which(name))
        executable(tools / "cc", "exit 0\n")
        executable(tools / "rustc", "echo 'rustc 1.99.0'\n")
        executable(tools / "cargo", cargo or cargo_writing())
        executable(tools / "bend", bend)
        if clang:
            executable(tools / "clang", "exit 0\n")
        return tools

    def env(self, root):
        return {"PATH": str(root / "tools"), "HOME": str(root), "LANG": "C"}

    def run_install(self, root):
        return subprocess.run(["/bin/sh", str(root / "scripts/install.sh")],
                              env=self.env(root), capture_output=True, timeout=10)

    def install(self, old_core=False, clang=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=clang)
            core = root / "bin/mailbend-core"
            if old_core:
                executable(core, "echo OLD_CORE\n")
            before = core.read_bytes() if core.exists() else None
            proc = self.run_install(root)
            return proc, before, core.read_bytes() if core.exists() else None

    def old_bin(self, root):
        """Every target as an old file; their bytes by name."""
        old = {}
        for name in TARGETS:
            executable(root / "bin" / name, f"echo old {name}\n")
            old[name] = (root / "bin" / name).read_bytes()
        return old

    def assert_unchanged(self, root, old):
        bin_dir = root / "bin"
        self.assertEqual(sorted(p.name for p in bin_dir.iterdir()), sorted(TARGETS))
        for name in TARGETS:
            self.assertEqual((bin_dir / name).read_bytes(), old[name], name)

    def test_missing_clang_warns_when_existing_core_is_kept(self):
        proc, before, after = self.install(old_core=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(after, before)
        self.assertIn(b"keeping existing bin/mailbend-core", proc.stderr)
        self.assertIn(b"may be out of date", proc.stderr)
        self.assertNotIn(b"will run main.bend through bend", proc.stdout)

    def test_missing_clang_without_core_uses_source_fallback(self):
        proc, _, after = self.install()
        self.assertEqual((proc.returncode, proc.stderr), (0, b""))
        self.assertIsNone(after)
        self.assertIn(b"will run main.bend through bend", proc.stdout)

    def test_clang_replaces_existing_core_without_stale_warning(self):
        proc, before, after = self.install(old_core=True, clang=True)
        self.assertEqual((proc.returncode, proc.stderr), (0, b""))
        self.assertNotEqual(after, before)
        self.assertIn(b"NEW_CORE", after)
        self.assertIn(b"restart any MCP server already running", proc.stdout)

    def test_published_binaries_are_executable_by_all_and_writable_only_by_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=True)
            proc = self.run_install(root)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            for name in TARGETS:
                self.assertEqual((root / "bin" / name).stat().st_mode & 0o777, 0o755, name)

    def test_reinstall_while_stdio_is_executing(self):
        sleep = pathlib.Path(shutil.which("sleep"))
        self.assertEqual(sleep.read_bytes()[:4], b"\x7fELF")
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=True)
            stdio = root / "bin/mailbend-stdio"
            core = root / "bin/mailbend-core"
            shutil.copy2(sleep, stdio)
            shutil.copy2(sleep, core)
            held = [subprocess.Popen([str(stdio), "120"]),
                    subprocess.Popen([str(core), "120"])]
            try:
                self.assertTrue(all(proc.poll() is None for proc in held))
                proc = self.run_install(root)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertTrue(all(proc.poll() is None for proc in held))
                for name in HELPERS:
                    self.assertEqual((root / "bin" / name).read_bytes(), NEW_HELPER)
                self.assertEqual(core.read_bytes(), NEW_CORE)
                self.assertEqual(sorted(path.name for path in (root / "bin").iterdir()), [
                    "mailbend-attach", "mailbend-core", "mailbend-stdio",
                    "mailbend-tls", "mailbend-typesafe",
                ])
            finally:
                for proc in held:
                    if proc.poll() is None:
                        proc.kill()
                    proc.wait(timeout=5)

    def test_failed_build_leaves_bin_unchanged_and_no_extra_files(self):
        cargo = """if [ "$1" = --version ]; then
  echo 'cargo 1.99.0'
  exit 0
fi
exit 1
"""
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, cargo=cargo)
            stdio = root / "bin/mailbend-stdio"
            tls = root / "bin/mailbend-tls"
            stdio.write_bytes(b"old-stdio")
            tls.write_bytes(b"old-tls")
            proc = self.run_install(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertEqual(stdio.read_bytes(), b"old-stdio")
            self.assertEqual(tls.read_bytes(), b"old-tls")
            self.assertEqual(sorted(p.name for p in (root / "bin").iterdir()),
                             ["mailbend-stdio", "mailbend-tls"])

    def check_failure_publishes_nothing(self, needle, clang=True, cargo=None, bend=CORE_BEND):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=clang, cargo=cargo, bend=bend)
            old = self.old_bin(root)
            proc = self.run_install(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn(needle, proc.stdout + proc.stderr)
            self.assert_unchanged(root, old)

    def test_a_staged_helper_that_cannot_run_publishes_nothing(self):
        for broken, needle in (("mailbend-tls", b"the built TLS helper cannot run"),
                               ("mailbend-typesafe", b"the built TypeSafe helper cannot run"),
                               ("mailbend-stdio", b"the built stdio helper cannot run")):
            with self.subTest(broken=broken):
                self.check_failure_publishes_nothing(needle, cargo=cargo_writing(broken))

    def test_a_failed_proof_publishes_nothing(self):
        bend = 'if [ "$1" = PROOF.bend ]; then echo "SOME PROOFS FAIL"; exit 1; fi\n' + CORE_BEND
        for clang in (True, False):
            with self.subTest(clang=clang):
                self.check_failure_publishes_nothing(b"SOME PROOFS FAIL", clang=clang, bend=bend)

    def test_a_failed_core_compile_publishes_nothing(self):
        bend = 'if [ "$1" = main.bend ]; then echo "clang failed" >&2; exit 1; fi\n'
        self.check_failure_publishes_nothing(b"clang failed", bend=bend)

    def test_a_signal_during_the_compile_leaves_bin_unchanged(self):
        sleep = shutil.which("sleep")
        for sig, code in ((signal.SIGHUP, 129), (signal.SIGINT, 130), (signal.SIGTERM, 143)):
            with self.subTest(signal=sig.name), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                marker = root / "compiling"
                bend = f"""if [ "$1" = main.bend ]; then
  printf 'partial' > "$3"
  : > {marker}
  exec {sleep} 30
fi
"""
                self.prepare(root, clang=True, bend=bend)
                old = self.old_bin(root)
                proc = subprocess.Popen(["/bin/sh", str(root / "scripts/install.sh")], env=self.env(root),
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                        start_new_session=True)
                try:
                    deadline = time.monotonic() + 10
                    while not marker.exists() and time.monotonic() < deadline:
                        time.sleep(0.05)
                    self.assertTrue(marker.exists())
                    os.killpg(proc.pid, sig)
                    self.assertEqual(proc.wait(timeout=10), code)
                finally:
                    if proc.poll() is None:
                        os.killpg(proc.pid, signal.SIGKILL)
                        proc.wait(timeout=5)
                self.assert_unchanged(root, old)

    def test_a_second_install_is_refused_while_one_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=True)
            old = self.old_bin(root)
            held = os.open(root / "bin", os.O_RDONLY)
            try:
                fcntl.flock(held, fcntl.LOCK_EX)
                proc = self.run_install(root)
            finally:
                os.close(held)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn(b"another install is running", proc.stderr)
            self.assert_unchanged(root, old)

    def test_siblings_left_by_a_killed_install_are_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=True)
            (root / "bin/mailbend-core.new.4242").write_bytes(b"partial")
            (root / "bin/mailbend-tls.new.1").write_bytes(b"partial")
            proc = self.run_install(root)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(sorted(p.name for p in (root / "bin").iterdir()), sorted(TARGETS))


if __name__ == "__main__":
    os.umask(0o022)
    unittest.main(verbosity=2)
