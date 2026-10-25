#!/usr/bin/env python3
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


def executable(path, text):
    path.write_text("#!/bin/sh\n" + text)
    path.chmod(0o755)


NEW_HELPER = b"#!/bin/sh\nexit 0\n"


class InstallTests(unittest.TestCase):
    def prepare(self, root, clang=False, cargo=None):
        tools = root / "tools"
        tools.mkdir()
        (root / "native").mkdir()
        (root / "scripts").mkdir()
        (root / "bin").mkdir()
        shutil.copy2(ROOT / "scripts/install.sh", root / "scripts/install.sh")
        for name in ("dirname", "sed", "mkdir", "cp", "mv", "rm"):
            (tools / name).symlink_to(shutil.which(name))
        executable(tools / "cc", "exit 0\n")
        executable(tools / "rustc", "echo 'rustc 1.99.0'\n")
        if cargo is None:
            cargo = """if [ "$1" = --version ]; then
  echo 'cargo 1.99.0'
  exit 0
fi
/bin/mkdir -p target/release
for name in mailbend-tls mailbend-attach mailbend-typesafe mailbend-stdio; do
  printf '#!/bin/sh\\nexit 0\\n' > "target/release/$name"
  /bin/chmod +x "target/release/$name"
done
"""
        executable(tools / "cargo", cargo)
        executable(tools / "bend", """if [ "$1" = main.bend ]; then
  printf '#!/bin/sh\necho NEW_CORE\n' > "$3"
  /bin/chmod +x "$3"
fi
""")
        if clang:
            executable(tools / "clang", "exit 0\n")
        return tools

    def install(self, old_core=False, clang=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=clang)
            core = root / "bin/mailbend-core"
            if old_core:
                executable(core, "echo OLD_CORE\n")
            before = core.read_bytes() if core.exists() else None
            env = {"PATH": str(root / "tools"), "HOME": str(root), "LANG": "C"}
            proc = subprocess.run(["/bin/sh", str(root / "scripts/install.sh")],
                                  env=env, capture_output=True, timeout=10)
            return proc, before, core.read_bytes() if core.exists() else None

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
                env = {"PATH": str(root / "tools"), "HOME": str(root), "LANG": "C"}
                proc = subprocess.run(["/bin/sh", str(root / "scripts/install.sh")],
                                      env=env, capture_output=True, timeout=10)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertTrue(all(proc.poll() is None for proc in held))
                for name in ("mailbend-tls", "mailbend-attach",
                             "mailbend-typesafe", "mailbend-stdio"):
                    self.assertEqual((root / "bin" / name).read_bytes(), NEW_HELPER)
                self.assertEqual(core.read_bytes(), b"#!/bin/sh\necho NEW_CORE\n")
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
            env = {"PATH": str(root / "tools"), "HOME": str(root), "LANG": "C"}
            proc = subprocess.run(["/bin/sh", str(root / "scripts/install.sh")],
                                  env=env, capture_output=True, timeout=10)
            self.assertNotEqual(proc.returncode, 0)
            self.assertEqual(stdio.read_bytes(), b"old-stdio")
            self.assertEqual(tls.read_bytes(), b"old-tls")
            self.assertEqual(sorted(p.name for p in (root / "bin").iterdir()),
                             ["mailbend-stdio", "mailbend-tls"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
