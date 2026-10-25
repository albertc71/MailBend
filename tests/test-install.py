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


class InstallTests(unittest.TestCase):
    def install(self, old_core=False, clang=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            tools = root / "tools"
            tools.mkdir()
            (root / "native").mkdir()
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            shutil.copy2(ROOT / "scripts/install.sh", root / "scripts/install.sh")
            for name in ("dirname", "sed", "mkdir", "cp"):
                (tools / name).symlink_to(shutil.which(name))
            executable(tools / "cc", "exit 0\n")
            executable(tools / "rustc", "echo 'rustc 1.99.0'\n")
            executable(tools / "cargo", """if [ "$1" = --version ]; then
  echo 'cargo 1.99.0'
  exit 0
fi
/bin/mkdir -p target/release
for name in mailbend-tls mailbend-attach mailbend-typesafe mailbend-stdio; do
  printf '#!/bin/sh\nexit 0\n' > "target/release/$name"
  /bin/chmod +x "target/release/$name"
done
""")
            executable(tools / "bend", """if [ "$1" = main.bend ]; then
  printf '#!/bin/sh\necho NEW_CORE\n' > "$3"
  /bin/chmod +x "$3"
fi
""")
            if clang:
                executable(tools / "clang", "exit 0\n")
            core = root / "bin/mailbend-core"
            if old_core:
                executable(core, "echo OLD_CORE\n")
            before = core.read_bytes() if core.exists() else None
            env = {"PATH": str(tools), "HOME": str(root), "LANG": "C"}
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
