#!/usr/bin/env python3
import fcntl
import hashlib
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
        shutil.copy2(ROOT / "scripts/install-layout.sh", root / "scripts/install-layout.sh")
        for name in ("dirname", "sed", "mkdir", "cp", "mv", "rm", "sync", "flock",
                     "stat", "id", "head", "readlink", "chmod", "mktemp", "ln",
                     "rmdir", "sha256sum"):
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

    def run_install(self, root, shell="/bin/sh", args=()):
        return subprocess.run([shell, str(root / "scripts/install.sh"), *args],
                              env=self.env(root), capture_output=True, timeout=10)

    def test_rollback_consumes_the_previous_slot_without_building(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=True)
            first = self.run_install(root)
            self.assertEqual(first.returncode, 0, first.stderr)
            a = (root / "bin").resolve()
            executable(root / "tools/bend", CORE_BEND.replace("NEW_CORE", "SECOND_CORE"))
            second = self.run_install(root)
            self.assertEqual(second.returncode, 0, second.stderr)
            b = (root / "bin").resolve()
            self.assertNotEqual(a, b)
            self.assertEqual((root / "bin.prev").resolve(), a)
            for name in ("cargo", "rustc", "clang", "bend", "cc"):
                executable(root / "tools" / name, "echo forbidden-build >&2; exit 91\n")
            rollback = self.run_install(root, args=("--rollback",))
            self.assertEqual((rollback.returncode, rollback.stderr), (0, b""))
            self.assertEqual((root / "bin").resolve(), a)
            self.assertFalse((root / "bin.prev").exists())
            selector = os.readlink(root / ".mailbend-install/current")
            again = self.run_install(root, args=("--rollback",))
            self.assertEqual((again.returncode, again.stderr), (0, b""))
            self.assertEqual(os.readlink(root / ".mailbend-install/current"), selector)
            self.assertTrue(b.is_dir(), "rollback must retain completed generations")

    def install(self, old_core=False, clang=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=clang)
            core = root / "bin/mailbend-core"
            if old_core:
                if clang:
                    self.old_bin(root)
                else:
                    executable(core, "echo OLD_CORE\n")
            before = core.read_bytes() if core.exists() else None
            proc = self.run_install(root)
            return proc, before, core.read_bytes() if core.exists() else None

    def old_bin(self, root, managed=True):
        """Independent complete A fixture, not an installer's generated expectation."""
        old = {}
        for name in TARGETS:
            executable(root / "bin" / name, f"echo old {name}\n")
            old[name] = (root / "bin" / name).read_bytes()
        if managed:
            generation = root / ".mailbend-install/generations/g.AAAAAAAAAAAA"
            state = root / ".mailbend-install/states/s.AAAAAAAAAAAA"
            generation.parent.mkdir(parents=True)
            state.mkdir(parents=True)
            (root / "bin").rename(generation)
            names = ("mailbend-core", *HELPERS)
            manifest = "mailbend-generation-v1\ngeneration=g.AAAAAAAAAAAA\n"
            manifest += "".join(f"{name} {hashlib.sha256(old[name]).hexdigest()} 0755\n"
                                for name in names)
            (generation / "MANIFEST").write_text(manifest)
            (state / "FORMAT").write_text("mailbend-install-state-v1\nkind=install\n"
                                          "active=g.AAAAAAAAAAAA\nprevious=none\n")
            (state / "active").symlink_to("../../generations/g.AAAAAAAAAAAA")
            (root / ".mailbend-install/current").symlink_to("states/s.AAAAAAAAAAAA")
            (root / "bin").symlink_to(".mailbend-install/current/active")
            (root / "bin.prev").symlink_to(".mailbend-install/current/previous")
        return old

    def test_fresh_compiled_install_selects_one_complete_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=True)
            proc = self.run_install(root)
            self.assertEqual((proc.returncode, proc.stderr), (0, b""))
            self.assertEqual(os.readlink(root / "bin"), ".mailbend-install/current/active")
            self.assertEqual(os.readlink(root / "bin.prev"), ".mailbend-install/current/previous")
            current = os.readlink(root / ".mailbend-install/current")
            self.assertRegex(current, r"^states/s\.[A-Za-z0-9]{12}$")
            state = root / ".mailbend-install" / current
            generation = (state / "active").resolve()
            self.assertEqual(generation.parent, root / ".mailbend-install/generations")
            self.assertEqual((state / "FORMAT").read_text(),
                             "mailbend-install-state-v1\nkind=install\n"
                             f"active={generation.name}\nprevious=none\n")
            expected = {name: NEW_HELPER for name in HELPERS}
            expected["mailbend-core"] = NEW_CORE
            self.assertEqual({p.name for p in generation.iterdir()}, set(TARGETS) | {"MANIFEST"})
            for name, value in expected.items():
                self.assertEqual((generation / name).read_bytes(), value)
            names = ("mailbend-core", *HELPERS)
            manifest = "mailbend-generation-v1\ngeneration=" + generation.name + "\n"
            manifest += "".join(f"{name} {hashlib.sha256(expected[name]).hexdigest()} 0755\n"
                                for name in names)
            self.assertEqual((generation / "MANIFEST").read_text(), manifest)

    def assert_unchanged(self, root, old):
        bin_dir = root / "bin"
        expected = set(TARGETS) | ({"MANIFEST"} if bin_dir.is_symlink() else set())
        self.assertEqual({p.name for p in bin_dir.iterdir()}, expected)
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
        self.assertIn(b"existing managed sessions keep their original helpers", proc.stdout)

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
            # Build an independent A fixture from already-installed system ELF.
            for name in TARGETS:
                shutil.copy2(sleep, root / "bin" / name)
            old = {name: (root / "bin" / name).read_bytes() for name in TARGETS}
            self.old_bin(root)
            generation = (root / "bin").resolve()
            for name in TARGETS:
                (generation / name).write_bytes(old[name])
            manifest = "mailbend-generation-v1\ngeneration=g.AAAAAAAAAAAA\n"
            manifest += "".join(f"{name} {hashlib.sha256(old[name]).hexdigest()} 0755\n"
                                for name in ("mailbend-core", *HELPERS))
            (generation / "MANIFEST").write_text(manifest)
            stdio = generation / "mailbend-stdio"
            core = generation / "mailbend-core"
            held = [subprocess.Popen([str(stdio), "120"]),
                    subprocess.Popen([str(core), "120"])]
            try:
                self.assertTrue(all(proc.poll() is None for proc in held))
                proc = self.run_install(root)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertTrue(all(proc.poll() is None for proc in held))
                for name in HELPERS:
                    self.assertEqual((root / "bin" / name).read_bytes(), NEW_HELPER)
                self.assertEqual((root / "bin/mailbend-core").read_bytes(), NEW_CORE)
                self.assertEqual(core.read_bytes(), old["mailbend-core"])
                self.assertEqual(sorted(path.name for path in (root / "bin").iterdir()), [
                    "MANIFEST", "mailbend-attach", "mailbend-core", "mailbend-stdio",
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
            old = self.old_bin(root, managed=clang)
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
            held = os.open(root, os.O_RDONLY)
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
            self.prepare(root)
            (root / "bin/mailbend-core.new.4242").write_bytes(b"partial")
            (root / "bin/mailbend-tls.new.1").write_bytes(b"partial")
            proc = self.run_install(root)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(sorted(p.name for p in (root / "bin").iterdir()), sorted(HELPERS))



    def test_compiled_migration_refuses_nonempty_legacy_before_build(self):
        for core in (False, True):
            with self.subTest(core=core), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                self.prepare(root, clang=True)
                if core:
                    old = self.old_bin(root, managed=False)
                else:
                    executable(root / "bin/mailbend-tls", "echo LEGACY\n")
                    old = {"mailbend-tls": (root / "bin/mailbend-tls").read_bytes()}
                proc = self.run_install(root)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn(b"new clean checkout", proc.stderr)
                self.assertFalse((root / "native/target").exists())
                self.assertTrue((root / "bin").is_dir())
                self.assertFalse((root / "bin").is_symlink())
                self.assertEqual({p.name: p.read_bytes() for p in (root / "bin").iterdir()}, old)

    def test_old_installer_empty_bin_lock_blocks_bootstrap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=True)
            inode = (root / "bin").stat().st_ino
            held = os.open(root / "bin", os.O_RDONLY)
            try:
                fcntl.flock(held, fcntl.LOCK_EX)
                proc = self.run_install(root)
            finally:
                os.close(held)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn(b"another install is running", proc.stderr)
            self.assertEqual((root / "bin").stat().st_ino, inode)
            self.assertFalse((root / ".mailbend-install").exists())
            self.assertFalse((root / "native/target").exists())

    def test_managed_missing_clang_cannot_fall_back_even_with_damaged_core(self):
        for missing in (False, True):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                self.prepare(root)
                self.old_bin(root)
                if missing:
                    (root / "bin/mailbend-core").unlink()
                selected = os.readlink(root / ".mailbend-install/current")
                proc = self.run_install(root)
                self.assertNotEqual(proc.returncode, 0)
                self.assertFalse((root / "native/target").exists())
                self.assertEqual(os.readlink(root / ".mailbend-install/current"), selected)

    def test_private_stage_modes_recover_but_unknown_residue_is_refused(self):
        for mode in (0o700, 0o755, 0o777):
            with self.subTest(mode=oct(mode)), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                self.prepare(root, clang=True)
                self.old_bin(root)
                stage = root / ".mailbend-install/generations/.stage-g.abcdefghijkl"
                stage.mkdir()
                stage.chmod(mode)
                (stage / "mailbend-core").write_bytes(b"unfinished")
                before = os.readlink(root / ".mailbend-install/current")
                proc = self.run_install(root)
                if mode == 0o777:
                    self.assertNotEqual(proc.returncode, 0)
                    self.assertEqual(os.readlink(root / ".mailbend-install/current"), before)
                    self.assertTrue(stage.is_dir())
                else:
                    self.assertEqual(proc.returncode, 0, proc.stderr)
                    self.assertFalse(stage.exists())

    def test_bootstrap_recovers_only_enumerated_preparation_states(self):
        self.assert_stage_unknown_names_are_retained()
        for case in ("metadata", "directories", "sentinel", "one-alias", "both-aliases",
                     "private-700", "private-755", "orphan-without-current", "unknown"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                self.prepare(root, clang=True)
                (root / "bin").rmdir()
                meta = root / ".mailbend-install"
                meta.mkdir()
                if case != "metadata":
                    (meta / "states").mkdir()
                    (meta / "generations").mkdir()
                if case in ("sentinel", "one-alias", "both-aliases"):
                    sentinel = meta / "states/bootstrap"
                    sentinel.mkdir()
                    (sentinel / "FORMAT").write_text("mailbend-install-state-v1\n"
                        "kind=bootstrap\nactive=none\nprevious=none\n")
                if case in ("one-alias", "both-aliases"):
                    (root / "bin").symlink_to(".mailbend-install/current/active")
                if case == "both-aliases":
                    (root / "bin.prev").symlink_to(".mailbend-install/current/previous")
                if case.startswith("private-"):
                    stage = meta / "states/.stage-bootstrap.abcdefghijkl"
                    stage.mkdir(mode=int(case.removeprefix("private-"), 8))
                    (stage / "FORMAT").write_bytes(b"partial")
                if case == "orphan-without-current":
                    (meta / "generations/g.AAAAAAAAAAAA").mkdir()
                if case == "unknown":
                    (meta / "unowned-history").write_bytes(b"do not erase")
                proc = self.run_install(root)
                if case in ("orphan-without-current", "unknown"):
                    self.assertNotEqual(proc.returncode, 0)
                    self.assertFalse((meta / "current").exists())
                    self.assertFalse((root / "native/target").exists())
                else:
                    self.assertEqual(proc.returncode, 0, proc.stderr)
                    self.assertEqual((root / "bin/mailbend-core").read_bytes(), NEW_CORE)
                    self.assertEqual((meta / "states/bootstrap/FORMAT").stat().st_mode & 0o777, 0o644)

    def assert_stage_unknown_names_are_retained(self):
        for name in ("mailbend-core mailbend-tls", "unknown", "FORMAT active",
                     "unexpected:mailbend-core", "unexpected:MANIFEST"):
            with self.subTest(stage_name=name), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                self.prepare(root, clang=True)
                self.old_bin(root)
                stage = root / ".mailbend-install/generations/.stage-g.abcdefghijkl"
                stage.mkdir(mode=0o700)
                (stage / name).write_bytes(b"must remain")
                proc = self.run_install(root)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual((stage / name).read_bytes(), b"must remain")
                self.assertFalse((root / "native/target").exists())

    def test_managed_corruption_fails_closed_for_launch_install_and_rollback(self):
        cases = ("missing-current", "bad-current", "missing-alias", "wrong-alias",
                 "missing-core", "member-link", "member-hardlink", "manifest-extra",
                 "record-extra", "record-nul", "record-cr", "record-no-lf",
                 "record-oversize", "wrong-state-mode", "wrong-file-mode")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                self.prepare(root, clang=True)
                self.old_bin(root)
                shutil.copy2(ROOT / "scripts/mailbend", root / "scripts/mailbend")
                meta = root / ".mailbend-install"
                state = meta / "states/s.AAAAAAAAAAAA"
                generation = (root / "bin").resolve()
                if case == "missing-current":
                    (meta / "current").unlink()
                elif case == "bad-current":
                    (meta / "current").unlink()
                    (meta / "current").symlink_to("states/../states/s.AAAAAAAAAAAA")
                elif case == "missing-alias":
                    (root / "bin.prev").unlink()
                elif case == "wrong-alias":
                    (root / "bin").unlink()
                    (root / "bin").symlink_to(generation)
                elif case == "missing-core":
                    (generation / "mailbend-core").unlink()
                elif case in ("member-link", "member-hardlink"):
                    core = generation / "mailbend-core"
                    data = core.read_bytes()
                    core.unlink()
                    target = root / "substitute"
                    target.write_bytes(data)
                    target.chmod(0o755)
                    if case == "member-link":
                        core.symlink_to(target)
                    else:
                        os.link(target, core)
                elif case == "manifest-extra":
                    with (generation / "MANIFEST").open("ab") as handle:
                        handle.write(b"unknown=field\n")
                elif case.startswith("record-"):
                    record = state / "FORMAT"
                    data = record.read_bytes()
                    data = {"record-extra": data + b"extra=field\n",
                            "record-nul": data + b"\0", "record-cr": data.replace(b"\n", b"\r\n"),
                            "record-no-lf": data[:-1], "record-oversize": b"x" * 257}[case]
                    record.write_bytes(data)
                elif case == "wrong-state-mode":
                    state.chmod(0o777)
                else:
                    (generation / "mailbend-tls").chmod(0o775)
                before = os.readlink(meta / "current") if (meta / "current").is_symlink() else None
                for shell in ("/bin/sh", "/bin/bash"):
                    for args in ((), ("--rollback",)):
                        proc = self.run_install(root, shell=shell, args=args)
                        self.assertNotEqual(proc.returncode, 0)
                launch = subprocess.run(["/bin/sh", str(root / "scripts/mailbend"), "tools"],
                                        env=self.env(root), capture_output=True, timeout=5)
                self.assertNotEqual(launch.returncode, 0)
                after = os.readlink(meta / "current") if (meta / "current").is_symlink() else None
                self.assertEqual(before, after)
                self.assertFalse((root / "native/target").exists())

    def test_readiness_is_fail_fast_under_root_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=True)
            self.old_bin(root)
            shutil.copy2(ROOT / "scripts/setup-cloud.sh", root / "scripts/setup-cloud.sh")
            held = os.open(root, os.O_RDONLY)
            try:
                fcntl.flock(held, fcntl.LOCK_EX)
                proc = subprocess.run(["/bin/sh", str(root / "scripts/setup-cloud.sh"), "--check"],
                                      env=self.env(root), capture_output=True, timeout=2)
            finally:
                os.close(held)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn(b"installation is busy", proc.stderr)



    def test_launcher_preserves_explicit_helpers_locale_and_argument_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=True)
            self.old_bin(root)
            shutil.copy2(ROOT / "scripts/mailbend", root / "scripts/mailbend")
            core = root / "bin/mailbend-core"
            executable(core, '"$MAILBEND_TLS_HELPER"\n"$MAILBEND_ATTACH_HELPER"\n'
                       '"$MAILBEND_TYPESAFE_HELPER"\nprintf "locale=%s\\n" "${LC_ALL-unset}"\n'
                       'printf "<%s>\\n" "$@"\n')
            override = root / "caller-helper"
            executable(override, "echo OVERRIDE_TLS\n")
            proc = subprocess.run(["/bin/sh", str(root / "scripts/mailbend"),
                                   "call", "tool name", '{"message":"two words"}'],
                                  env={**self.env(root), "MAILBEND_TLS_HELPER": str(override),
                                       "MAILBEND_ATTACH_HELPER": "", "LC_ALL": "C.UTF-8"},
                                  capture_output=True, timeout=5)
            self.assertEqual((proc.returncode, proc.stderr), (0, b""))
            self.assertEqual(proc.stdout, b"OVERRIDE_TLS\nold mailbend-attach\n"
                             b"old mailbend-typesafe\nlocale=C.UTF-8\n"
                             b'<call>\n<tool name>\n<{"message":"two words"}>\n')

    def test_launcher_executes_captured_a_when_selector_changes_before_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            tools = self.prepare(root, clang=True)
            self.old_bin(root)
            shutil.copy2(ROOT / "scripts/mailbend", root / "scripts/mailbend")
            (tools / "readlink").unlink()
            executable(tools / "readlink", f'{shutil.which("readlink")} "$@"\n'
                       'if [ "${CAPTURE_PAUSE:-0}" = 1 ] && '
                       '[ "$3" = "$HOME/.mailbend-install/current" ]; then\n'
                       '  : > "$HOME/captured"\n'
                       '  while [ ! -f "$HOME/release" ]; do /bin/sleep 0.01; done\nfi\n')
            launch = subprocess.Popen(["/bin/sh", str(root / "scripts/mailbend"), "tools"],
                        env={**self.env(root), "CAPTURE_PAUSE": "1"}, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not (root / "captured").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / "captured").exists(), "current read barrier was not reached")
                update = self.run_install(root)
                self.assertEqual(update.returncode, 0, update.stderr)
                (root / "release").touch()
                stdout, stderr = launch.communicate(timeout=5)
                self.assertEqual((launch.returncode, stdout, stderr),
                                 (0, b"old mailbend-core\n", b""))
            finally:
                (root / "release").touch()
                if launch.poll() is None:
                    os.killpg(launch.pid, signal.SIGKILL)
                launch.communicate(timeout=5)

    def test_uncertain_rollback_and_retry_each_require_successful_final_flush(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            tools = self.prepare(root, clang=True)
            self.old_bin(root)
            installed = self.run_install(root)
            self.assertEqual(installed.returncode, 0, installed.stderr)
            (tools / "sync").unlink()
            executable(tools / "sync", f'''
if [ "$2" = "$HOME/.mailbend-install" ] && [ -f "$HOME/fail-final" ]; then
  state=$({shutil.which("readlink")} "$HOME/.mailbend-install/current")
  if /bin/grep -qx kind=rollback "$HOME/.mailbend-install/$state/FORMAT"; then exit 71; fi
fi
exec {shutil.which("sync")} "$@"
''')
            (root / "fail-final").touch()
            for _ in range(2):
                proc = self.run_install(root, args=("--rollback",))
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn(b"durability is uncertain", proc.stderr)
                self.assertEqual((root / "bin").resolve().name, "g.AAAAAAAAAAAA")
            (root / "fail-final").unlink()
            proc = self.run_install(root, args=("--rollback",))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn(b"rollback already applied", proc.stdout)
            # A later install creates a new slot; a bare rollback applies to it.
            later = self.run_install(root)
            self.assertEqual(later.returncode, 0, later.stderr)
            self.assertEqual((root / "bin.prev").resolve().name, "g.AAAAAAAAAAAA")
            again = self.run_install(root, args=("--rollback",))
            self.assertEqual(again.returncode, 0, again.stderr)
            self.assertEqual((root / "bin").resolve().name, "g.AAAAAAAAAAAA")

    def test_bad_previous_blocks_mutation_but_not_structurally_valid_active_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=True)
            self.old_bin(root)
            proc = self.run_install(root)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            shutil.copy2(ROOT / "scripts/mailbend", root / "scripts/mailbend")
            (root / "bin.prev/mailbend-core").write_bytes(b"damaged prior generation")
            before = os.readlink(root / ".mailbend-install/current")
            for args in ((), ("--rollback",)):
                proc = self.run_install(root, args=args)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn(b"manifest mismatch", proc.stderr)
            launch = subprocess.run(["/bin/sh", str(root / "scripts/mailbend"), "tools"],
                                    env=self.env(root), capture_output=True, timeout=5)
            self.assertEqual((launch.returncode, launch.stdout, launch.stderr), (0, b"NEW_CORE\n", b""))
            self.assertEqual(os.readlink(root / ".mailbend-install/current"), before)



    def test_restrictive_umask_does_not_change_final_modes_or_widen_private_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.prepare(root, clang=True)
            root.chmod(0o700)
            proc = subprocess.run(["/bin/sh", str(root / "scripts/install.sh")],
                                  env=self.env(root), capture_output=True, timeout=10, umask=0o077)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(root.stat().st_mode & 0o7777, 0o700)
            for path in (root / ".mailbend-install").rglob("*"):
                if path.is_symlink():
                    continue
                expected = 0o755 if path.is_dir() or path.name in TARGETS else 0o644
                self.assertEqual(path.stat().st_mode & 0o7777, expected, str(path))

    def test_writable_nonsticky_ancestor_is_refused_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            root = parent / "checkout"
            root.mkdir(mode=0o700)
            self.prepare(root, clang=True)
            parent.chmod(0o777)
            try:
                proc = self.run_install(root)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn(b"writable checkout ancestor", proc.stderr)
                self.assertFalse((root / "native/target").exists())
                self.assertFalse((root / ".mailbend-install").exists())
            finally:
                parent.chmod(0o700)

    def test_checkout_permission_refusals_name_path_mode_and_preserve_the_tree(self):
        cases = ((False, 0o775, "0775"), (True, 0o775, "0775"),
                 (True, 0o757, "0757"), (True, 0o4755, "04755"),
                 (True, 0o2755, "02755"), (True, 0o1755, "01755"),
                 (True, 0o2775, "02775"))
        for managed, mode, observed in cases:
            with self.subTest(managed=managed, mode=observed), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory) / "checkout with spaces"
                root.mkdir(mode=0o700)
                self.prepare(root, clang=True)
                commands = (("install.sh", ()),)
                if managed:
                    self.old_bin(root)
                    for name in ("mailbend", "setup-cloud.sh"):
                        shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
                    commands += (("install.sh", ("--rollback",)),
                                 ("mailbend", ("tools",)), ("setup-cloud.sh", ("--check",)))

                def snapshot():
                    result = {}
                    for path in root.rglob("*"):
                        info = path.lstat()
                        if path.is_symlink():
                            content = ("link", os.readlink(path))
                        elif path.is_file():
                            content = ("file", path.read_bytes())
                        else:
                            content = ("directory",)
                        result[str(path.relative_to(root))] = (
                            info.st_mode, info.st_ino, info.st_nlink, content)
                    return result

                root.chmod(mode)
                self.assertEqual(root.stat().st_mode & 0o7777, mode)
                before = snapshot()
                expected = (
                    f"mailbend: invalid installation: unsafe checkout permissions: {root} "
                    f"(mode {observed}); root owner must be UID {os.getuid()}. "
                    "Group or world write and setuid, setgid or sticky bits are forbidden. "
                    "Only if local policy permits, the owner may remove unwanted bits "
                    "(group-write/setgid only: chmod g-w,g-s); otherwise use a new private checkout. "
                    "See README.md#checkout-permissions\n").encode()
                try:
                    for shell in ("/bin/sh", "/bin/bash"):
                        for script, args in commands:
                            with self.subTest(shell=shell, script=script, args=args):
                                proc = subprocess.run([shell, str(root / "scripts" / script), *args],
                                                      env=self.env(root), capture_output=True, timeout=5)
                                self.assertEqual((proc.returncode, proc.stdout, proc.stderr),
                                                 (2, b"", expected))
                                self.assertEqual(root.stat().st_mode & 0o7777, mode)
                                self.assertEqual(snapshot(), before)
                finally:
                    root.chmod(0o700)

    def test_allowed_checkout_modes_keep_managed_launch_and_readiness_available(self):
        for mode in (0o700, 0o750, 0o755):
            with self.subTest(mode=oct(mode)), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                self.prepare(root, clang=True)
                (root / "tools/sh").symlink_to("/bin/sh")
                old = self.old_bin(root)
                for name in ("mailbend", "setup-cloud.sh"):
                    shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
                root.chmod(mode)
                for shell in ("/bin/sh", "/bin/bash"):
                    for script, args in (("mailbend", ("tools",)), ("setup-cloud.sh", ("--check",))):
                        proc = subprocess.run([shell, str(root / "scripts" / script), *args],
                                              env=self.env(root), capture_output=True, timeout=5)
                        self.assertEqual((proc.returncode, proc.stderr), (0, b""))
                        self.assertEqual(root.stat().st_mode & 0o7777, mode)
                        self.assert_unchanged(root, old)



    def test_manifest_hash_failure_after_compile_preserves_the_active_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            bend = CORE_BEND.replace("\nfi\n", '\n  : > "$HOME/hashfail"\nfi\n')
            tools = self.prepare(root, clang=True, bend=bend)
            old = self.old_bin(root)
            (tools / "sha256sum").unlink()
            executable(tools / "sha256sum", '[ ! -f "$HOME/hashfail" ] || exit 71\n'
                       f'exec {shutil.which("sha256sum")} "$@"\n')
            proc = self.run_install(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertTrue((root / "hashfail").exists(), "failure must happen after core compile")
            self.assert_unchanged(root, old)



    def test_foreign_member_metadata_is_refused_at_the_stat_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            tools = self.prepare(root, clang=True)
            self.old_bin(root)
            shutil.copy2(ROOT / "scripts/mailbend", root / "scripts/mailbend")
            (tools / "stat").unlink()
            executable(tools / "stat", f'actual=$({shutil.which("stat")} "$@") || exit 1\n'
                       'case "$4" in */generations/g.AAAAAAAAAAAA/mailbend-core)\n'
                       '  if [ "$2" = "%u %a %h %d %s" ]; then '
                       'printf "999999 %s\\n" "${actual#* }"; exit; fi ;;\nesac\n'
                       'printf "%s\\n" "$actual"\n')
            proc = self.run_install(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn(b"file owner, mode, links or size", proc.stderr)
            launch = subprocess.run(["/bin/sh", str(root / "scripts/mailbend"), "tools"],
                                    env=self.env(root), capture_output=True, timeout=5)
            self.assertNotEqual(launch.returncode, 0)
            self.assertIn(b"file owner, mode, links or size", launch.stderr)
            self.assertFalse((root / "native/target").exists())

    def test_root_path_replacement_is_refused_before_layout_mutation(self):
        self.check_root_path_replacement(before_stat=True)

    def test_root_path_replacement_after_stat_fails_without_layout_mutation(self):
        self.check_root_path_replacement(before_stat=False)

    def check_root_path_replacement(self, *, before_stat):
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            root = parent / "checkout"
            root.mkdir(mode=0o700)
            tools = self.prepare(root, clang=True)
            shared_tools = parent / "tools"
            tools.rename(shared_tools)
            (shared_tools / "stat").unlink()
            replacement = 'if [ "$4" = "$HOME" ] && [ ! -e "$HOME.moved" ]; then\n' \
                          '  /bin/mv "$HOME" "$HOME.moved" || exit 73\n' \
                          '  /bin/mkdir -m 700 "$HOME" || exit 74\nfi\n'
            observation = f'actual=$({shutil.which("stat")} "$@") || exit 1\n' \
                          'printf "%s\\n" "$actual"\n'
            executable(shared_tools / "stat", replacement + observation if before_stat
                       else observation + replacement)
            proc = subprocess.run(["/bin/sh", str(root / "scripts/install.sh")],
                                  env={"HOME": str(root), "PATH": str(shared_tools), "LANG": "C"},
                                  capture_output=True, timeout=10)
            self.assertNotEqual(proc.returncode, 0)
            if before_stat:
                self.assertIn(b"checkout root moved or was replaced", proc.stderr)
            moved = parent / "checkout.moved"
            self.assertTrue(moved.is_dir())
            self.assertTrue(root.is_dir())
            self.assertNotEqual((root.stat().st_dev, root.stat().st_ino),
                                (moved.stat().st_dev, moved.stat().st_ino))
            self.assertFalse((root / ".mailbend-install").exists())
            self.assertFalse((parent / "checkout.moved/.mailbend-install").exists())



    def test_temporary_selector_collision_does_not_write_inside_an_existing_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            tools = self.prepare(root, clang=True)
            old = self.old_bin(root)
            (tools / "mktemp").unlink()
            executable(tools / "mktemp", 'if [ "$1" = -u ]; then\n'
                       '  path="$HOME/.mailbend-install/.current-new.abcdefghijkl"\n'
                       '  /bin/mkdir -p "$path"\n  printf "%s\\n" "$path"\n  exit\nfi\n'
                       f'exec {shutil.which("mktemp")} "$@"\n')
            before = os.readlink(root / ".mailbend-install/current")
            proc = self.run_install(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn(b"cannot allocate temporary selector", proc.stderr)
            self.assertEqual(os.readlink(root / ".mailbend-install/current"), before)
            collision = root / ".mailbend-install/.current-new.abcdefghijkl"
            self.assertEqual(list(collision.iterdir()), [], "ln must refuse the destination itself")
            self.assert_unchanged(root, old)



    def test_compiler_symlink_output_cannot_change_the_published_core_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            bend = 'if [ "$1" = main.bend ]; then /bin/ln -s "$HOME/bin/mailbend-core" "$3"; fi\n'
            self.prepare(root, clang=True, bend=bend)
            old = self.old_bin(root)
            core = (root / "bin").resolve() / "mailbend-core"
            before = core.stat()
            proc = self.run_install(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn(b"not a nonempty direct file", proc.stderr)
            after = core.stat()
            self.assertEqual((after.st_ino, after.st_mode, after.st_ctime_ns),
                             (before.st_ino, before.st_mode, before.st_ctime_ns))
            self.assert_unchanged(root, old)

    def test_failed_compile_cannot_retry_through_a_symlink_to_the_selected_core(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            bend = ('if [ "$1" = main.bend ]; then\n'
                    '  if [ ! -f "$HOME/attempted" ]; then\n'
                    '    : > "$HOME/attempted"\n'
                    '    /bin/ln -s "$HOME/bin/mailbend-core" "$3"\n'
                    '    exit 1\n  fi\n'
                    '  : > "$HOME/retried"\n  printf unsafe > "$3"\nfi\n')
            self.prepare(root, clang=True, bend=bend)
            old = self.old_bin(root)
            core = (root / "bin").resolve() / "mailbend-core"
            before = core.stat()
            selector = os.readlink(root / ".mailbend-install/current")
            proc = self.run_install(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn(b"not a nonempty direct file", proc.stderr)
            self.assertTrue((root / "attempted").exists())
            self.assertFalse((root / "retried").exists())
            after = core.stat()
            self.assertEqual((after.st_ino, after.st_mode, after.st_ctime_ns),
                             (before.st_ino, before.st_mode, before.st_ctime_ns))
            self.assertEqual(os.readlink(root / ".mailbend-install/current"), selector)
            self.assert_unchanged(root, old)

    def test_failed_compile_can_retry_a_safe_partial_direct_file(self):
        for partial in ("", "partial"):
            with self.subTest(partial=partial), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                bend = ('if [ "$1" = main.bend ] && [ ! -f "$HOME/attempted" ]; then\n'
                        '  : > "$HOME/attempted"\n'
                        f'  printf "{partial}" > "$3"\n  exit 1\nfi\n' + CORE_BEND)
                self.prepare(root, clang=True, bend=bend)
                self.old_bin(root)
                proc = self.run_install(root)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertTrue((root / "attempted").exists())
                self.assertEqual((root / "bin/mailbend-core").read_bytes(), NEW_CORE)


if __name__ == "__main__":
    os.umask(0o022)
    unittest.main(verbosity=2)
