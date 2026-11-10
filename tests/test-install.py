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
        executable(tools / "getconf", "echo 'glibc 2.34'\n")
        executable(tools / "rustc", "echo 'rustc 1.99.0'\n")
        executable(tools / "cargo", cargo or cargo_writing())
        executable(tools / "bend", bend)
        if clang:
            executable(tools / "clang", "exit 0\n")
        return tools

    def env(self, root):
        return {"PATH": str(root / "tools"), "HOME": str(root), "LANG": "C"}

    def run_install(self, root, shell="/bin/sh"):
        return subprocess.run([shell, str(root / "scripts/install.sh")],
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

    def test_missing_clang_refuses_existing_core_without_changing_any_binary(self):
        old = {
            "mailbend-tls": b"#!/bin/sh\necho OLD_TLS\n",
            "mailbend-attach": b"#!/bin/sh\necho OLD_ATTACH\n",
            "mailbend-typesafe": b"#!/bin/sh\necho OLD_TYPESAFE\n",
            "mailbend-stdio": b"#!/bin/sh\necho OLD_STDIO\n",
            "mailbend-core": b"#!/bin/sh\necho OLD_CORE\n",
        }
        outputs = {
            "mailbend-tls": b"OLD_TLS\n",
            "mailbend-attach": b"OLD_ATTACH\n",
            "mailbend-typesafe": b"OLD_TYPESAFE\n",
            "mailbend-stdio": b"OLD_STDIO\n",
            "mailbend-core": b"OLD_CORE\n",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root)
            for name, data in old.items():
                path = root / "bin" / name
                path.write_bytes(data)
                path.chmod(0o755)
            proc = self.run_install(root)
            with self.subTest(observation="refusal"):
                self.assertNotEqual(proc.returncode, 0, "existing compiled installation must be refused")
                self.assertIn(b"clang", proc.stderr)
                self.assertIn(b"Install clang and rerun", proc.stderr)
            with self.subTest(observation="no build"):
                self.assertFalse((root / "native/target").exists(),
                                 "the refusal must precede building any helper")
            self.assertEqual(sorted(p.name for p in (root / "bin").iterdir()), sorted(TARGETS))
            for name in TARGETS:
                with self.subTest(binary=name, observation="bytes"):
                    self.assertEqual((root / "bin" / name).read_bytes(), old[name],
                                     "previous executable bytes must remain unchanged")
                with self.subTest(binary=name, observation="behavior"):
                    result = subprocess.run([str(root / "bin" / name)], env=self.env(root),
                                            capture_output=True, timeout=2)
                    self.assertEqual((result.returncode, result.stdout, result.stderr),
                                     (0, outputs[name], b""), "previous behavior must remain unchanged")

    def test_missing_clang_without_core_uses_source_fallback(self):
        proc, _, after = self.install()
        self.assertEqual((proc.returncode, proc.stderr), (0, b""))
        self.assertIsNone(after)
        self.assertIn(b"will run main.bend through bend", proc.stdout)

    def test_missing_clang_with_nonexecutable_core_uses_source_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root)
            core = root / "bin/mailbend-core"
            core.write_bytes(b"nonexecutable core")
            core.chmod(0o644)
            proc = self.run_install(root)
            self.assertEqual((proc.returncode, proc.stderr), (0, b""))
            self.assertEqual(core.read_bytes(), b"nonexecutable core")
            self.assertFalse(os.access(core, os.X_OK))
            self.assertIn(b"will run main.bend through bend", proc.stdout)
            for name in HELPERS:
                self.assertEqual((root / "bin" / name).read_bytes(), NEW_HELPER)

    def test_clang_replaces_existing_core_without_stale_warning(self):
        proc, before, after = self.install(old_core=True, clang=True)
        self.assertEqual((proc.returncode, proc.stderr), (0, b""))
        self.assertNotEqual(after, before)
        self.assertIn(b"NEW_CORE", after)
        self.assertIn(b"restart any MCP server already running", proc.stdout)

    def test_compilation_requires_glibc_234_before_building(self):
        for version in (None, "", "glibc 2.33", "glibc 1.99", "musl 1.2", "glibc invalid",
                        "glibc 2.34 private-server-marker", "private-server-marker\nglibc 2.34",
                        "glibc 99999999999999999999999999.34"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                tools = self.prepare(root, clang=True, bend="echo build-ran >&2; exit 1\n")
                old = self.old_bin(root)
                if version is None:
                    (tools / "getconf").unlink()
                else:
                    executable(tools / "getconf", f"printf '%s\\n' '{version}'\n")
                proc = self.run_install(root)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(proc.stderr,
                                 b"mailbend: the compiled core needs glibc 2.34 or newer\n")
                self.assertFalse((root / "native/target").exists())
                self.assert_unchanged(root, old)

    def test_cargo_build_selects_every_helper_even_with_stale_targets(self):
        expected = ('mailbend-tls', 'mailbend-attach', 'mailbend-typesafe', 'mailbend-stdio')
        cargo = r'''if [ "$1" = --version ]; then
  echo 'cargo 1.99.0'
  exit 0
fi
printf '%s\0' "$@" > "$HOME/cargo-argv"
/bin/mkdir -p target/release
while [ "$#" -gt 0 ]; do
  case "$1" in
    build|--release|--locked|--quiet) shift ;;
    -p)
      [ "$#" -ge 2 ] || exit 91
      printf '#!/bin/sh\nexit 0\n' > "target/release/$2"
      /bin/chmod +x "target/release/$2"
      shift 2 ;;
    *) exit 92 ;;
  esac
done
'''
        for stale in (False, True):
            with self.subTest(stale=stale), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                self.prepare(root, clang=True, cargo=cargo)
                if stale:
                    target = root / 'native/target/release'
                    target.mkdir(parents=True)
                    for name in expected:
                        executable(target / name, '# stale artifact\nexit 0\n')
                proc = self.run_install(root)
                argv = (root / 'cargo-argv').read_bytes().split(b'\0')
                self.assertEqual(argv.pop(), b'')
                self.assertEqual(argv[:4], [b'build', b'--release', b'--locked', b'--quiet'])
                self.assertEqual(argv[4::2], [b'-p'] * len(expected))
                self.assertCountEqual(argv[5::2], [name.encode() for name in expected],
                                      'Cargo must select every installed helper exactly once')
                self.assertEqual((proc.returncode, proc.stderr), (0, b''))
                for name in expected:
                    self.assertEqual((root / 'bin' / name).read_bytes(), NEW_HELPER,
                                     'installed helper must be freshly built, not a stale target')


    def test_supported_glibc_builds_and_getconf_receives_its_exact_argument(self):
        for version in ("2.34", "2.35", "3.0"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                tools = self.prepare(root, clang=True)
                executable(tools / "getconf", '[ "$#" = 1 ] && '
                           '[ "$1" = GNU_LIBC_VERSION ] || exit 1\n'
                           f"echo 'glibc {version}'\n")
                proc = self.run_install(root)
                self.assertEqual((proc.returncode, proc.stderr), (0, b""))
                self.assertEqual((root / "bin/mailbend-core").read_bytes(), NEW_CORE)

    def test_no_clang_does_not_require_getconf(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            tools = self.prepare(root)
            (tools / "getconf").unlink()
            proc = self.run_install(root)
            self.assertEqual((proc.returncode, proc.stderr), (0, b""))
            self.assertIn(b"run main.bend through bend", proc.stdout)

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

    def check_failure_publishes_nothing(self, needle, clang=True, cargo=None, bend=CORE_BEND,
                                       shell="/bin/sh"):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=clang, cargo=cargo, bend=bend)
            old = self.old_bin(root)
            if not clang:
                (root / "bin/mailbend-core").chmod(0o644)
            proc = self.run_install(root, shell=shell)
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

    def test_clang_disappearing_during_proofs_does_not_publish_helpers(self):
        bend = '''if [ "$1" = PROOF.bend ]; then
  /bin/rm "$HOME/tools/clang"
fi
if [ "$1" = main.bend ]; then
  echo "clang disappeared" >&2
  exit 1
fi
'''
        # dash can find removed commands in its cache; bash exposes a second probe.
        for shell in ("/bin/sh", "/bin/bash"):
            with self.subTest(shell=shell):
                self.check_failure_publishes_nothing(b"clang disappeared", bend=bend, shell=shell)

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
