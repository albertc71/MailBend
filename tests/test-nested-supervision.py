"""Hosted-only synthetic controls for the nested validation process boundary."""
import importlib.util
import fcntl
import builtins
import io
import os
from pathlib import Path
import signal
import select
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("nested_supervision", Path(__file__).with_name("nested_supervision.py"))
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)
REAL_POPEN = subprocess.Popen
REAL_PIDFD = os.pidfd_open
REAL_SEND = signal.pidfd_send_signal
REAL_OPEN = builtins.open
REAL_POLL = select.poll


def alive(fd):
    poll = REAL_POLL()
    poll.register(fd, select.POLLIN)
    return not poll.poll(0)


class SupervisionControls(unittest.TestCase):
    def recorded(self, source):
        return ('import os as _fo, pathlib as _fp\n'
                '_fs=_fp.Path("/proc/self/stat").read_text().rsplit(")",1)[1].split()[19]\n'
                '_ff=_fo.open(_fo.environ["SUPERVISION_FIXTURE_RECORDS"],_fo.O_WRONLY|_fo.O_CREAT|_fo.O_APPEND,0o600)\n'
                '_fo.write(_ff,(str(_fo.getpid())+" "+_fs+"\\n").encode()); _fo.close(_ff)\n' + source)

    def run_case(self, source, *, children=0, expect_survivors=False, **limits):
        bounds = {"rss_kib": 262144, "seconds": 4, "cleanup_seconds": 2,
                  "output_bytes": 65536, "interval": .01}
        bounds.update(limits)
        roots, handles, accounted = [], {}, set()
        def launch(*args, **kwargs):
            process = REAL_POPEN(*args, **kwargs)
            roots.append(process)
            accounted.add(process.pid)
            try:
                handles[process.pid] = REAL_PIDFD(process.pid)
            except OSError:
                # Still the direct unreaped child; no PID lookup or group signal.
                try:
                    os.kill(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=.2)
                raise
            return process
        with tempfile.TemporaryDirectory() as directory:
            records = Path(directory) / "records"
            errors = set()
            def collect(deadline):
                try:
                    with REAL_OPEN(records, "r") as stream:
                        raw = stream.read(8193)
                    if len(raw) > 8192:
                        raise ValueError("fixture record limit")
                except FileNotFoundError:
                    return
                except (OSError, ValueError):
                    errors.add("records")
                    return
                for line in raw.splitlines():
                    if time.monotonic() >= deadline:
                        errors.add("deadline")
                        return
                    try:
                        pid, started = map(int, line.split())
                        if pid in handles:
                            continue
                        with REAL_OPEN(f"/proc/{pid}/stat") as stream:
                            before = stream.read().rsplit(")", 1)[1].split()
                        if int(before[19]) != started or before[0] in ("Z", "X"):
                            accounted.add(pid)
                            continue
                        fd = REAL_PIDFD(pid)
                        try:
                            with REAL_OPEN(f"/proc/{pid}/stat") as stream:
                                after = stream.read().rsplit(")", 1)[1].split()
                            if int(after[19]) != started:
                                raise ProcessLookupError()
                            handles[pid] = fd
                            accounted.add(pid)
                        except BaseException:
                            os.close(fd)
                            raise
                    except (FileNotFoundError, ProcessLookupError):
                        accounted.add(pid)
                    except (OSError, ValueError, IndexError):
                        errors.add("identity")

            def live_handles():
                live = set()
                for pid, fd in handles.items():
                    try:
                        if alive(fd):
                            live.add(pid)
                    except (OSError, ValueError):
                        errors.add("readiness")
                        live.add(pid)
                return live
            try:
                with patch.dict(os.environ, {"SUPERVISION_FIXTURE_RECORDS": str(records)}):
                    with patch.object(runner.subprocess, "Popen", side_effect=launch):
                        result = runner.supervise([sys.executable, "-I", "-S", "-B", "-c", self.recorded(source)],
                                                  runner.Limits(**bounds), secrets=("synthetic-secret",))
            finally:
                deadline = time.monotonic() + 2
                collect(deadline)
                survivors = live_handles()
                try:
                    while time.monotonic() < deadline:
                        collect(deadline)
                        for fd in handles.values():
                            if time.monotonic() >= deadline:
                                errors.add("deadline")
                                break
                            try:
                                REAL_SEND(fd, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                            except (OSError, ValueError):
                                errors.add("signal")
                        remaining = live_handles()
                        if not remaining and len(accounted) >= (1 + children if roots else 0):
                            break
                        time.sleep(.005)
                    for process in roots:
                        try:
                            process.wait(timeout=max(0, deadline - time.monotonic()))
                        except (OSError, subprocess.TimeoutExpired):
                            errors.add("wait")
                    remaining = live_handles()
                    if len(accounted) < (1 + children if roots else 0):
                        errors.add("unobserved fixture child")
                finally:
                    for fd in handles.values():
                        try:
                            os.close(fd)
                        except OSError:
                            errors.add("close")
                self.assertFalse(remaining or errors, "independent fixture cleanup failed: " + str(sorted(errors)))
            result["fixture_survivors_before_fallback"] = len(survivors)
            if not expect_survivors:
                self.assertFalse(survivors, "supervisor left recorded fixture processes alive")
            return result

    def test_high_virtual_reservation_is_not_resident_memory(self):
        result = self.run_case('import mmap,time\nm=mmap.mmap(-1,9*1024**3,prot=0)\nprint("reserved",flush=True)\ntime.sleep(.1)')
        self.assertEqual((result["reason"], result["exit_code"], result["stdout"]),
                         ("completed", 0, "reserved\n"))
        self.assertTrue(result["cleanup_complete"])

    def test_nonzero_exit_retains_redacted_stderr(self):
        result = self.run_case('import sys\nprint("allocation failed synthetic-secret",file=sys.stderr)\nsys.exit(7)')
        self.assertEqual((result["reason"], result["exit_code"]), ("exit", 7))
        self.assertTrue(result["stderr"] == "allocation failed <redacted>\n", "stderr redaction differs")

    def test_over_cap_secret_prefix_is_never_displayed(self):
        secret = "synthetic-secret"
        result = self.run_case('import os\nos.write(2,b"x"*250+b"synthetic-secret")', output_bytes=256)
        self.assertEqual(result["reason"], "output_limit")
        self.assertTrue(result["output_omitted"]["stderr"])
        self.assertTrue("synthe" not in result["stderr"], "partial fixture secret was displayed")

    def test_secret_across_read_chunk_and_excerpt_is_redacted(self):
        result = self.run_case('import os,sys\nos.write(2,b"x"*65530+b"synthetic-secret"+b"y"*4090)\nsys.exit(7)',
                               output_bytes=131072)
        self.assertEqual(result["reason"], "exit")
        self.assertTrue(result["excerpt_truncated"]["stderr"])
        self.assertTrue("synthetic" not in result["stderr"], "fixture secret prefix was displayed")
        self.assertTrue("-secret" not in result["stderr"], "fixture secret suffix was displayed")

    def test_encoded_secret_is_redacted_before_display(self):
        result = self.run_case('import os,sys\nos.write(2,b"c3ludGhldGljLXNlY3JldA== marker")\nsys.exit(7)')
        self.assertTrue(result["stderr"] == "<redacted> marker", "encoded fixture redaction differs")

    def test_forced_stop_does_not_display_a_partial_secret(self):
        result = self.run_case('import os,time\nos.write(2,b"synthe")\ntime.sleep(30)', seconds=.15)
        self.assertEqual(result["reason"], "deadline")
        self.assertTrue(result["output_omitted"]["stderr"])
        self.assertTrue("synthe" not in result["stderr"], "partial fixture secret was displayed")

    def test_first_cancellation_is_preserved(self):
        delivered = []
        def during_cleanup(fd, sig, *args):
            if not delivered:
                os.kill(os.getpid(), signal.SIGINT)
                delivered.append(signal.SIGINT)
            return REAL_SEND(fd, sig, *args)
        with patch.object(runner.signal, "pidfd_send_signal", side_effect=during_cleanup):
            result = self.run_case('import os,signal,time\nos.kill(os.getppid(),signal.SIGTERM)\ntime.sleep(30)')
        self.assertEqual(delivered, [signal.SIGINT])
        self.assertEqual((result["reason"], result["cancel_signal"]), ("cancelled", signal.SIGTERM))
        self.assertTrue(result["cleanup_complete"])

    def test_ignored_sigchld_does_not_auto_reap_owned_leader(self):
        previous = signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        try:
            result = self.run_case('print("waitable")')
            self.assertEqual((result["reason"], result["exit_code"]), ("completed", 0))
            self.assertEqual(signal.getsignal(signal.SIGCHLD), signal.SIG_IGN)
        finally:
            signal.signal(signal.SIGCHLD, previous)

    def test_high_numbered_pidfds_are_supported(self):
        original = os.pidfd_open
        def high_fd(pid, flags=0):
            fd = original(pid, flags)
            try:
                return fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 2048)
            finally:
                os.close(fd)
        with patch.object(runner.os, "pidfd_open", side_effect=high_fd):
            result = self.run_case('print("high fd")')
        self.assertEqual((result["reason"], result["exit_code"]), ("completed", 0))

    def test_timeout_stops_the_owned_session(self):
        result = self.run_case('import time\ntime.sleep(30)', seconds=.15)
        self.assertEqual(result["reason"], "deadline")
        self.assertTrue(result["cleanup_complete"])

    def test_each_output_stream_has_its_own_cap(self):
        for stream in (1, 2):
            with self.subTest(stream=stream):
                result = self.run_case(f'import os\nos.write({stream}, b"x"*65537)')
                self.assertEqual(result["reason"], "output_limit")
                self.assertTrue(result["cleanup_complete"])

    def test_memory_is_aggregated_across_same_session_groups(self):
        child = self.recorded('import time\nx=bytearray(45*1024**2)\ntime.sleep(30)')
        source = ('import subprocess,sys,time\n'
                  f'p=subprocess.Popen([sys.executable,"-c",{child!r}],process_group=0)\n'
                  'x=bytearray(45*1024**2)\ntime.sleep(30)')
        result = self.run_case(source, children=1, rss_kib=81920)
        self.assertEqual(result["reason"], "rss_limit")
        self.assertTrue(result["cleanup_complete"])

    def test_one_allocation_fits_the_same_aggregate_threshold(self):
        result = self.run_case('import time\nx=bytearray(45*1024**2)\ntime.sleep(.1)', rss_kib=81920)
        self.assertEqual(result["reason"], "completed")

    def test_primary_exit_with_live_child_is_not_success(self):
        child = self.recorded('import signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\ntime.sleep(30)')
        source = ('import os,pathlib,subprocess,sys,time\n'
                  f'subprocess.Popen([sys.executable,"-c",{child!r}],process_group=0)\n'
                  'while len(pathlib.Path(os.environ["SUPERVISION_FIXTURE_RECORDS"]).read_text().splitlines()) < 2: time.sleep(.005)\n')
        result = self.run_case(source, children=1)
        self.assertEqual(result["reason"], "residual_children")
        self.assertTrue(result["cleanup_complete"])

    def test_long_observation_checks_the_shared_deadline(self):
        original = os.scandir
        class SlowInventory:
            def __enter__(self):
                self.entries = original("/proc")
                return self
            def __iter__(self):
                for entry in self.entries:
                    time.sleep(.02)
                    yield entry
            def __exit__(self, *_):
                self.entries.close()
        with patch.object(runner.os, "scandir", side_effect=lambda path:
                          SlowInventory() if path == "/proc" else original(path)):
            result = self.run_case('import time\ntime.sleep(30)', seconds=.03, cleanup_seconds=.06)
        self.assertEqual(result["reason"], "deadline")
        self.assertLess(result["elapsed_seconds"], 2)

    def test_failed_leader_admission_still_cleans_separate_group_child(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "child"
            child = self.recorded('import os,pathlib,time\n'
                     f'pathlib.Path({str(marker)!r}).write_text(str(os.getpid())+" "+pathlib.Path("/proc/self/stat").read_text().rsplit(")",1)[1].split()[19])\n'
                     'time.sleep(30)')
            source = ('import subprocess,sys,time\n'
                      f'subprocess.Popen([sys.executable,"-c",{child!r}],process_group=0)\n'
                      'time.sleep(30)')
            real_open = os.pidfd_open
            first = True
            def admission(pid, flags=0):
                nonlocal first
                if first:
                    first = False
                    deadline = time.monotonic() + 2
                    while not marker.exists() and time.monotonic() < deadline:
                        time.sleep(.005)
                    raise PermissionError("injected admission failure")
                return real_open(pid, flags)
            with patch.object(runner.os, "pidfd_open", side_effect=admission):
                result = self.run_case(source, children=1)
            self.assertEqual(result["reason"], "observation")
            self.assertTrue(result["cleanup_complete"])
            self.assertTrue(marker.exists())
            pid, started = marker.read_text().split()
            try:
                fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
            except FileNotFoundError:
                fields = None
            self.assertTrue(fields is None or fields[19] != started or fields[0] in ("Z", "X"))

    def test_persistent_leader_stat_failure_still_stops_owned_processes(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "child"
            child = self.recorded(f'import os,pathlib,time\npathlib.Path({str(marker)!r}).write_text(str(os.getpid()))\ntime.sleep(30)')
            source = f'import subprocess,sys,time\nsubprocess.Popen([sys.executable,"-c",{child!r}],process_group=0)\ntime.sleep(30)'
            leader = []
            def admission(pid, flags=0):
                if not leader:
                    leader.append(pid)
                    deadline = time.monotonic() + 2
                    while not marker.exists() and time.monotonic() < deadline:
                        time.sleep(.005)
                return REAL_PIDFD(pid, flags)
            def observation(path, *args, **kwargs):
                if leader and str(path) == f"/proc/{leader[0]}/stat":
                    raise PermissionError("persistent leader observation")
                return REAL_OPEN(path, *args, **kwargs)
            with patch.object(runner.os, "pidfd_open", side_effect=admission), patch.object(builtins, "open", side_effect=observation):
                result = self.run_case(source, children=1)
            self.assertTrue(marker.exists())
            self.assertEqual(result["reason"], "observation")
            self.assertFalse(result["cleanup_complete"])
            self.assertEqual(result["fixture_survivors_before_fallback"], 0)

    def test_persistent_pidfd_failure_keeps_direct_child_ownership(self):
        with patch.object(runner.os, "pidfd_open", side_effect=PermissionError("pidfd denied")):
            result = self.run_case('import time\ntime.sleep(30)')
        self.assertEqual(result["reason"], "observation")
        self.assertEqual(result["fixture_survivors_before_fallback"], 0)

    def test_identity_change_between_observation_and_admission_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "child"
            child = self.recorded(f'import os,pathlib,time\npathlib.Path({str(marker)!r}).write_text(str(os.getpid()))\ntime.sleep(30)')
            source = f'import subprocess,sys,time\nsubprocess.Popen([sys.executable,"-c",{child!r}])\ntime.sleep(30)'
            reads = []
            admitted = []
            def admission(pid, flags=0):
                if not admitted:
                    admitted.append(pid)
                    deadline = time.monotonic() + 2
                    while (not marker.exists() or not marker.read_text()) and time.monotonic() < deadline:
                        time.sleep(.005)
                return REAL_PIDFD(pid, flags)
            def observation(path, *args, **kwargs):
                stream = REAL_OPEN(path, *args, **kwargs)
                if marker.exists() and str(path) == f"/proc/{marker.read_text()}/stat":
                    raw = stream.read()
                    stream.close()
                    reads.append(True)
                    if len(reads) == 2:
                        prefix, fields = raw.rsplit(b")", 1)
                        values = fields.split()
                        values[19] = b"1"
                        raw = prefix + b") " + b" ".join(values)
                    return io.BytesIO(raw)
                return stream
            with patch.object(builtins, "open", side_effect=observation), patch.object(runner.os, "pidfd_open", side_effect=admission):
                result = self.run_case(source, children=1)
            self.assertGreaterEqual(len(reads), 2)
            self.assertEqual(result["reason"], "observation")
            self.assertEqual(result["fixture_survivors_before_fallback"], 0)

    def test_known_child_new_session_is_failure_not_silent_omission(self):
        with tempfile.TemporaryDirectory() as directory:
            marker, go = Path(directory) / "child", Path(directory) / "go"
            child = self.recorded('import os,pathlib,time\n'
                f'pathlib.Path({str(marker)!r}).write_text(str(os.getpid()))\n'
                f'while not pathlib.Path({str(go)!r}).exists(): time.sleep(.005)\n'
                'os.setsid()\ntime.sleep(30)')
            source = f'import subprocess,sys,time\nsubprocess.Popen([sys.executable,"-c",{child!r}])\ntime.sleep(30)'
            reads = []
            def observation(path, *args, **kwargs):
                stream = REAL_OPEN(path, *args, **kwargs)
                if marker.exists() and str(path) == f"/proc/{marker.read_text()}/stat":
                    raw = stream.read()
                    stream.close()
                    reads.append(True)
                    if len(reads) == 2:
                        go.write_text("escape after observed admission")
                    return io.BytesIO(raw)
                return stream
            with patch.object(builtins, "open", side_effect=observation):
                result = self.run_case(source, children=1)
            self.assertTrue(go.exists())
            self.assertEqual(result["reason"], "observation")
            self.assertEqual(result["fixture_survivors_before_fallback"], 0)

    def cleanup_only_case(self, status):
        with tempfile.TemporaryDirectory() as directory:
            parent, marker = Path(directory) / "parent", Path(directory) / "child"
            child = self.recorded(f'import os,pathlib,time\nos.write(2,b"synthe")\npathlib.Path({str(marker)!r}).write_text(str(os.getpid()))\ntime.sleep(30)')
            source = ('import os,pathlib,subprocess,sys,time\n'
                      f'pathlib.Path({str(parent)!r}).write_text(str(os.getpid()))\n'
                      f'subprocess.Popen([sys.executable,"-c",{child!r}],process_group=0)\n'
                      f'while not pathlib.Path({str(marker)!r}).exists(): time.sleep(.005)\n'
                      f'sys.exit({status})\n')
            original = os.scandir
            first = True
            hidden = []
            class Snapshot:
                def __init__(self, entries):
                    self.entries = entries
                def __enter__(self):
                    return iter(self.entries)
                def __exit__(self, *_):
                    pass
            def inventory(path):
                nonlocal first
                if path != "/proc" or not first:
                    return original(path)
                first = False
                deadline = time.monotonic() + 2
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(.005)
                leader = REAL_PIDFD(int(parent.read_text()))
                try:
                    while alive(leader) and time.monotonic() < deadline:
                        time.sleep(.005)
                finally:
                    os.close(leader)
                omitted = marker.read_text()
                hidden.append(omitted)
                with original(path) as entries:
                    return Snapshot([entry for entry in entries if entry.name != omitted])
            with patch.object(runner.os, "scandir", side_effect=inventory):
                result = self.run_case(source, children=1)
            self.assertEqual(len(hidden), 1)
            self.assertTrue(result["cleanup_complete"])
            return result

    def test_cleanup_only_child_discovery_cannot_pass(self):
        result = self.cleanup_only_case(0)
        self.assertEqual((result["reason"], result["exit_code"]), ("residual_children", 0))

    def test_nonzero_late_residual_cannot_display_partial_secret(self):
        result = self.cleanup_only_case(7)
        self.assertEqual((result["reason"], result["exit_code"]), ("exit", 7))
        self.assertTrue(result["residual_cleanup"])
        self.assertTrue(result["output_omitted"]["stderr"])
        self.assertTrue("synthe" not in result["stderr"], "partial fixture secret was displayed")

    def test_invalid_first_child_pidfd_does_not_starve_second_child_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            first_marker, second_marker = Path(directory) / "first", Path(directory) / "second"
            children = [self.recorded(f'import os,pathlib,time\npathlib.Path({str(marker)!r}).write_text(str(os.getpid()))\ntime.sleep(30)')
                        for marker in (first_marker, second_marker)]
            source = ('import subprocess,sys,time\n' + ''.join(
                f'subprocess.Popen([sys.executable,"-c",{child!r}],process_group=0)\n' for child in children)
                + 'time.sleep(30)')
            admitted = []
            original_inventory = os.scandir
            ordered = []
            class Snapshot:
                def __init__(self, entries):
                    self.entries = entries
                def __enter__(self):
                    return iter(self.entries)
                def __exit__(self, *_):
                    pass
            def inventory(path):
                if path != "/proc":
                    return original_inventory(path)
                bad, good = first_marker.read_text(), second_marker.read_text()
                with original_inventory(path) as entries:
                    entries = sorted(entries, key=lambda entry: 0 if entry.name == bad else 1 if entry.name == good else 2)
                names = [entry.name for entry in entries]
                if bad in names and good in names:
                    ordered.append(names.index(bad) < names.index(good))
                return Snapshot(entries)
            def admission(pid, flags=0):
                if not admitted:
                    admitted.append(pid)
                    deadline = time.monotonic() + 2
                    while (not first_marker.exists() or not second_marker.exists()
                           or not first_marker.read_text() or not second_marker.read_text()) and time.monotonic() < deadline:
                        time.sleep(.005)
                return REAL_PIDFD(pid, flags)
            class Readiness:
                def __init__(self):
                    self.real = REAL_POLL()
                    self.fd = None
                def register(self, fd, events):
                    self.fd = fd
                    self.real.register(fd, events)
                def poll(self, timeout):
                    with REAL_OPEN(f"/proc/self/fdinfo/{self.fd}") as stream:
                        lines = stream.read().splitlines()
                    pid = next((line.split()[1] for line in lines if line.startswith("Pid:")), None)
                    if first_marker.exists() and pid == first_marker.read_text():
                        return [(self.fd, select.POLLNVAL)]
                    return self.real.poll(timeout)
            with patch.object(runner.select, "poll", Readiness), patch.object(runner.os, "pidfd_open", side_effect=admission), patch.object(runner.os, "scandir", side_effect=inventory):
                result = self.run_case(source, children=2, expect_survivors=True)
            self.assertTrue(first_marker.exists() and second_marker.exists())
            self.assertTrue(ordered and all(ordered))
            self.assertEqual(result["reason"], "observation")
            self.assertFalse(result["cleanup_complete"])
            self.assertEqual(result["fixture_survivors_before_fallback"], 1)

    def test_other_session_sentinel_survives(self):
        sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], start_new_session=True)
        try:
            result = self.run_case('import time\ntime.sleep(30)', seconds=.1)
            self.assertEqual(result["reason"], "deadline")
            self.assertIsNone(sentinel.poll())
        finally:
            sentinel.kill()
            sentinel.wait(timeout=2)

    def test_one_signal_failure_does_not_hide_later_cleanup(self):
        original = signal.pidfd_send_signal
        first = True
        def send(fd, sig, *args):
            nonlocal first
            if first:
                first = False
                raise PermissionError("injected signal failure")
            return original(fd, sig, *args)
        with patch.object(runner.signal, "pidfd_send_signal", side_effect=send):
            result = self.run_case('import time\ntime.sleep(30)', seconds=.1)
        self.assertEqual(result["reason"], "deadline")
        self.assertIn("signal", result["later_failures"])
        self.assertTrue(result["cleanup_complete"])

    def test_invalid_limits_are_rejected_before_launch(self):
        for limits in ({"output_bytes": 1.5}, {"seconds": float("nan")}, {"rss_kib": True}):
            with self.subTest(limits=limits):
                with self.assertRaisesRegex(ValueError, "invalid supervision limits"):
                    self.run_case('raise SystemExit("must not launch")', **limits)

    def test_observation_denial_is_not_zero_memory(self):
        original = os.scandir
        def denied(path):
            if path == "/proc":
                raise PermissionError("private-path")
            return original(path)
        with patch.object(runner.os, "scandir", side_effect=denied):
            result = self.run_case('import time\ntime.sleep(30)')
        self.assertEqual(result["reason"], "observation")
        self.assertFalse(result["cleanup_complete"])
        self.assertTrue("private-path" not in str(result), "observation exception details were displayed")

    def test_normal_output_is_drained_after_primary_exit(self):
        result = self.run_case('import os\nos.write(1,b"a"*65536)\nos.write(2,b"b"*65536)')
        self.assertEqual(result["reason"], "completed")
        self.assertEqual(result["stdout"], "a"*65536)
        self.assertEqual(result["stderr"], "b"*65536)


if __name__ == "__main__":
    unittest.main()
