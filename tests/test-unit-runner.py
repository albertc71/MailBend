#!/usr/bin/env python3
"""Exercise the unit-runner shell CLI with a synthetic PATH compiler."""
import os
import signal
import time
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="unit-contract-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "tests/unit").mkdir(parents=True)
        (self.root / "bin").mkdir()
        (self.root / "spool").mkdir()
        allowed_tools = self.root / "allowed-tools"
        allowed_tools.mkdir()
        for command in ("sh", "dirname", "sed", "cmp", "diff"):
            (allowed_tools / command).symlink_to(shutil.which(command, path=os.defpath))
        (allowed_tools / "python3").symlink_to(sys.executable)
        for name in ("run-unit.sh", "run-unit.py"):
            shutil.copyfile(SOURCE / name, self.root / "tests" / name)
        self.env = {**os.environ, "PATH": str(self.root / "bin") + os.pathsep + str(allowed_tools),
                    "TMPDIR": str(self.root / "spool")}
        self.compiler("print('ok')")

    def compiler(self, body):
        path = self.root / "bin/bend"
        path.write_text(f"#!{sys.executable}\n" + body + "\n")
        path.chmod(0o755)

    def unit(self, name, content="#|ok\n"):
        (self.root / "tests/unit" / (name + ".bend")).write_text(content)

    def run_cli(self, *args, timeout=15):
        command = ["sh", "tests/run-unit.sh", *args]
        with subprocess.Popen(command, cwd=self.root, env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired as error:
                stdout, stderr = self.stop_runner(process)
                error.output = stdout
                error.stderr = stderr + f"\nfixture runner exit: {process.returncode}".encode()
                raise
            return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)

    def stop_runner(self, process):
        if process.poll() is None:
            process.terminate()
        try:
            return process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            return process.communicate()

    def test_fixture_deadline_requests_cleanup_before_killing_runner(self):
        self.unit('a')
        self.compiler("""import os, signal, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path('pid').write_text(str(os.getpid()))
time.sleep(60)
""")
        try:
            with self.assertRaises(subprocess.TimeoutExpired) as expired:
                self.run_cli(timeout=2)
            pid = int(self.wait_file('pid').read_text())
            self.assert_stopped(pid)
            self.assertEqual(list((self.root / 'spool').iterdir()), [], expired.exception.stderr)
        finally:
            if (self.root / 'pid').exists():
                try:
                    os.kill(int((self.root / 'pid').read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_inherited_compiler_is_never_used_by_failure_fixture(self):
        fallback = self.root / 'fallback'
        fallback.mkdir()
        marker = self.root / 'fallback-used'
        sentinel = fallback / 'bend'
        sentinel.write_text(f"#!{sys.executable}\n" + f"""import os, signal
from pathlib import Path
Path({str(marker)!r}).touch()
os.kill(os.getppid(), signal.SIGTERM)
""")
        sentinel.chmod(0o755)
        result = subprocess.run(
            [sys.executable, str(SOURCE / 'test-unit-runner.py'),
             'RunnerTests.test_launch_and_input_errors_stop_owned_compiler'],
            env={**os.environ, 'PATH': str(fallback) + os.pathsep + os.defpath},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(marker.exists(), 'fixture fell back to an inherited Bend')

    def test_two_jobs_overlap_and_report_in_inventory_order(self):
        self.unit("a")
        self.unit("b")
        self.compiler("""from pathlib import Path
import sys, time
name = Path(sys.argv[1]).stem
Path(name + '.started').touch()
if name == 'a':
    deadline = time.monotonic() + 3
    while not Path('b.done').exists():
        if time.monotonic() > deadline:
            raise SystemExit(7)
        time.sleep(.01)
else:
    Path('b.done').touch()
print('ok')""")
        result = self.run_cli("--jobs", "2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, b"PASS tests/unit/a.bend\nPASS tests/unit/b.bend\nunit: 2 passed, 0 failed\n")

    def test_serial_and_batched_inventory_and_cap(self):
        for name in ("a", "b", "c", "d", "e"):
            self.unit(name)
        self.compiler("""import fcntl, os, sys, time
from pathlib import Path
name = Path(sys.argv[1]).stem
with open('lock', 'w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    active = int(Path('active').read_text()) if Path('active').exists() else 0
    active += 1
    Path('active').write_text(str(active))
    with open('events', 'a') as events:
        events.write('start ' + name + ' ' + str(active) + '\\n')
time.sleep(.08)
print('ok')
with open('lock', 'w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    Path('active').write_text(str(int(Path('active').read_text()) - 1))
""")
        for args, cap in [((), 1), (("--jobs", "2"), 2), (("--jobs", "8"), 8)]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, b"PASS tests/unit/a.bend\nPASS tests/unit/b.bend\nPASS tests/unit/c.bend\nPASS tests/unit/d.bend\nPASS tests/unit/e.bend\nunit: 5 passed, 0 failed\n")
                events = (self.root / 'events').read_text().splitlines()
                self.assertEqual(sorted(line.split()[1] for line in events), ['a', 'b', 'c', 'd', 'e'])
                self.assertLessEqual(max(int(line.split()[2]) for line in events), cap)
                (self.root / 'events').unlink()

    def test_byte_comparison_exit_status_and_later_tests(self):
        for name in ('a', 'b', 'c', 'd', 'e', 'f'):
            self.unit(name)
        self.compiler("""import os, sys
from pathlib import Path
name = Path(sys.argv[1]).stem
if name == 'a':
    print('wrong')
elif name == 'b':
    print('ok')
    sys.exit(3)
elif name == 'c':
    os.write(2, b'ok\\n')
elif name == 'd':
    print('ok ')
elif name == 'e':
    os.write(1, b'ok')
else:
    print('ok')
""")
        for args in ((), ('--jobs', '2')):
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 1)
            verdicts = [line for line in result.stdout.splitlines()
                        if line.startswith((b'PASS ', b'FAIL ', b'unit:'))]
            self.assertEqual(verdicts, [b'FAIL tests/unit/a.bend', b'FAIL tests/unit/b.bend',
                                       b'PASS tests/unit/c.bend', b'FAIL tests/unit/d.bend',
                                       b'FAIL tests/unit/e.bend', b'PASS tests/unit/f.bend',
                                       b'unit: 2 passed, 4 failed'])

    def test_expected_lines_anywhere_and_missing_final_newline(self):
        self.unit('a', '#|first\nignored\n#|last')
        self.compiler("import os\nos.write(1, b'first\\nlast')")
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, b'PASS tests/unit/a.bend\nunit: 1 passed, 0 failed\n')

    def test_empty_inventory_and_missing_compiler_launch_nothing(self):
        self.compiler("from pathlib import Path\nPath('launched').touch()")
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'launched').exists())
        self.unit('a')
        (self.root / 'bin/bend').unlink()
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b'unit:', result.stdout)
        self.assertIn(b'missing bend', result.stderr)

    def wait_file(self, name, process=None):
        deadline = time.monotonic() + 5
        path = self.root / name
        while not path.exists():
            if time.monotonic() > deadline:
                if process is not None:
                    stdout, stderr = self.stop_runner(process)
                    self.fail(f"compiler did not create {name}; exit {process.returncode}; "
                              f"stdout {stdout!r}; stderr {stderr!r}")
                self.fail('compiler did not create ' + name)
            time.sleep(.01)
        return path

    def assert_stopped(self, pid):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            status = Path('/proc') / str(pid) / 'stat'
            if not status.exists() or status.read_text().split()[2] == 'Z':
                return
            time.sleep(.02)
        self.fail('owned compiler process still running: ' + str(pid))

    def test_signals_stop_descendants_and_remove_spool(self):
        self.unit('a')
        self.unit('b')
        self.unit('c')
        self.compiler("""import os, signal, subprocess, sys, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen([sys.executable, '-c', 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'])
name = Path(sys.argv[1]).stem
Path('pids-' + name).write_text(str(os.getpid()) + ' ' + str(child.pid))
Path('ready-' + name).touch()
while True:
    time.sleep(1)
""")
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signum=signum):
                process = subprocess.Popen(['sh', 'tests/run-unit.sh', '--jobs', '2'], cwd=self.root,
                                           env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                pids = []
                try:
                    self.wait_file('ready-a', process)
                    self.wait_file('ready-b', process)
                    pids = [int(pid) for name in ('a', 'b')
                            for pid in (self.root / ('pids-' + name)).read_text().split()]
                    process.send_signal(signum)
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertNotEqual(process.returncode, 0)
                    self.assertNotIn(b'unit:', stdout)
                    self.assertFalse((self.root / 'ready-c').exists())
                    for pid in pids:
                        self.assert_stopped(pid)
                    self.assertEqual(list((self.root / 'spool').iterdir()), [])
                finally:
                    self.stop_runner(process)
                    for pid in pids:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    for name in ('a', 'b'):
                        (self.root / ('ready-' + name)).unlink(missing_ok=True)

    def test_launch_and_input_errors_stop_owned_compiler(self):
        self.unit('a')
        self.unit('b')
        sed = self.root / 'bin/sed'
        sed.write_text(f"#!{sys.executable}\n" + """import os, sys, time
from pathlib import Path
if sys.argv[-1].endswith('/b.bend'):
    deadline = time.monotonic() + 5
    while not Path('ready').exists():
        if time.monotonic() > deadline:
            sys.exit(8)
        time.sleep(.01)
os.execv('/usr/bin/sed', ['sed', *sys.argv[1:]])
""")
        sed.chmod(0o755)
        for failure in ('launch', 'input'):
            with self.subTest(failure=failure):
                self.unit('b')
                self.compiler("""import os, signal, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path('pid').write_text(str(os.getpid()))
""" + ("Path('bin/bend').unlink()\n" if failure == 'launch' else
       "Path('tests/unit/b.bend').unlink()\n") + "Path('ready').touch()\ntime.sleep(60)")
                (self.root / 'pid').unlink(missing_ok=True)
                pid = None
                try:
                    result = self.run_cli('--jobs', '2')
                    pid = int(self.wait_file('pid').read_text())
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn(b'unit:', result.stdout)
                    self.assert_stopped(pid)
                    self.assertEqual(list((self.root / 'spool').iterdir()), [])
                finally:
                    if (self.root / 'pid').exists():
                        pid = int((self.root / 'pid').read_text())
                    if pid:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    (self.root / 'ready').unlink(missing_ok=True)

    def test_output_is_spooled_and_difference_is_twenty_lines(self):
        self.unit('a')
        self.compiler("""import os, stat
assert stat.S_ISREG(os.fstat(1).st_mode)
assert stat.S_ISREG(os.fstat(2).st_mode)
assert os.environ['BEND_NO_TELEMETRY'] == '1'
block = b'wrong\\n' * 1024
for _ in range(1024):
    os.write(1, block)
""")
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.splitlines()[:4],
                         [b'FAIL tests/unit/a.bend', b'1c1,1048576', b'< ok', b'---'])
        self.assertEqual(result.stdout.splitlines()[4:-1], [b'> wrong'] * 17)
        self.assertEqual(result.stdout.splitlines()[-1], b'unit: 0 passed, 1 failed')
        self.assertEqual(list((self.root / 'spool').iterdir()), [])

    def test_descendants_finish_before_comparison_and_next_batch(self):
        for name in ('a', 'b', 'c'):
            self.unit(name)
        self.compiler("""import os, signal, sys, time
from pathlib import Path
name = Path(sys.argv[1]).stem
if name in ('a', 'b'):
    leader = os.getpid()
    child = os.fork()
    if child == 0:
        def finish(signum, frame):
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            state = Path('/proc') / str(leader) / 'stat'
            Path('reserved-' + name).write_text(state.read_text().split()[2] if state.exists() else 'gone')
            os.write(1, b'late\\n')
            Path('wrote-' + name).touch()
        signal.signal(signal.SIGTERM, finish)
        Path('child-' + name).write_text(str(os.getpid()))
        while True:
            time.sleep(.01)
    while not Path('child-' + name).exists():
        time.sleep(.01)
    print('ok')
else:
    for earlier in ('a', 'b'):
        state = Path('/proc') / Path('child-' + earlier).read_text() / 'stat'
        if state.exists() and state.read_text().split()[2] != 'Z':
            print('prior batch still alive')
    print('ok')
""")
        try:
            result = self.run_cli('--jobs', '2')
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            verdicts = [line for line in result.stdout.splitlines()
                        if line.startswith((b'PASS ', b'FAIL ', b'unit:'))]
            self.assertEqual(verdicts, [b'FAIL tests/unit/a.bend', b'FAIL tests/unit/b.bend',
                                       b'PASS tests/unit/c.bend', b'unit: 1 passed, 2 failed'])
            for name in ('a', 'b'):
                self.assertEqual((self.root / ('reserved-' + name)).read_text(), 'Z')
                self.assertTrue((self.root / ('wrote-' + name)).exists())
                self.assert_stopped(int((self.root / ('child-' + name)).read_text()))
        finally:
            for path in self.root.glob('child-*'):
                try:
                    os.kill(int(path.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_signal_cleans_up_each_command_helper(self):
        self.unit('a')
        self.compiler("print('wrong')")
        for command in ('sed', 'cmp', 'diff'):
            with self.subTest(command=command):
                helper = self.root / 'bin' / command
                helper.write_text(f'#!{sys.executable}\n' + """import os, signal, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path('helper-pid').write_text(str(os.getpid()))
Path('helper-ready').touch()
time.sleep(60)
""")
                helper.chmod(0o755)
                process = subprocess.Popen(['sh', 'tests/run-unit.sh'], cwd=self.root,
                                           env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                pid = None
                try:
                    self.wait_file('helper-ready', process)
                    pid = int((self.root / 'helper-pid').read_text())
                    process.terminate()
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertNotEqual(process.returncode, 0)
                    self.assertNotIn(b'unit:', stdout)
                    self.assert_stopped(pid)
                    self.assertEqual(list((self.root / 'spool').iterdir()), [])
                finally:
                    self.stop_runner(process)
                    if pid:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    helper.unlink()
                    (self.root / 'helper-ready').unlink(missing_ok=True)

    def test_ignored_sigchld_is_reset_at_both_cli_entries(self):
        self.unit('a')
        for entry in ([sys.executable, 'tests/run-unit.py'], ['sh', 'tests/run-unit.sh']):
            with self.subTest(entry=entry):
                result = subprocess.run(entry, cwd=self.root, env=self.env,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        preexec_fn=lambda: signal.signal(signal.SIGCHLD, signal.SIG_IGN),
                                        timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, b'PASS tests/unit/a.bend\nunit: 1 passed, 0 failed\n')

    def test_hidden_files_stay_outside_shell_inventory(self):
        self.unit('.hidden', '#|unexpected\n')
        self.unit('a')
        self.compiler("""from pathlib import Path
import sys
with open('events', 'a') as events:
    events.write(sys.argv[1] + '\\n')
print('ok')
""")
        result = self.run_cli('--jobs', '2')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, b'PASS tests/unit/a.bend\nunit: 1 passed, 0 failed\n')
        self.assertEqual((self.root / 'events').read_text(), 'tests/unit/a.bend\n')
        (self.root / 'tests/unit/a.bend').unlink()
        (self.root / 'events').unlink()
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b'unit:', result.stdout)
        self.assertFalse((self.root / 'events').exists())

    def test_leading_zero_decimal_job_count(self):
        self.unit('a')
        result = self.run_cli('--jobs', '0' * 5000 + '1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, b'PASS tests/unit/a.bend\nunit: 1 passed, 0 failed\n')

    def test_invalid_arguments_launch_nothing(self):
        self.unit("a")
        self.compiler("from pathlib import Path\nPath('launched').touch()\nprint('ok')")
        for args in [("--jobs", "0"), ("--jobs", "9"), ("--jobs", "-1"),
                     ("--jobs", "1.0"), ("--jobs", "x"), ("--jobs",),
                     ("--jobs=2",), ("--jobs", "2", "--jobs", "2"), ("extra",)]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(b"unit:", result.stdout)
                self.assertFalse((self.root / "launched").exists())


if __name__ == "__main__":
    unittest.main()
