#!/usr/bin/env python3
"""Run sorted unit files in bounded batches, with private on-disk output."""
from dataclasses import dataclass
from pathlib import Path
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


@dataclass
class Job:
    source: Path
    expected: Path
    actual: Path
    process: subprocess.Popen


class Supervisor:
    def __init__(self):
        self.processes = []
        self.stop = 0

    def cancel(self, signum, _frame):
        self.stop = signum

    def check(self):
        if self.stop:
            raise InterruptedError(f"interrupted by signal {self.stop}")

    def launch(self, argv, **kwargs):
        self.check()
        process = subprocess.Popen(argv, start_new_session=True, **kwargs)
        self.processes.append(process)
        return process

    def wait(self, process):
        while True:
            self.check()
            exited = os.waitid(os.P_PID, process.pid,
                               os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if exited is not None:
                return self.finish(process)
            time.sleep(.01)

    def group_alive(self, pgid):
        for entry in Path("/proc").iterdir():
            if not entry.name.isdecimal():
                continue
            try:
                data = (entry / "stat").read_bytes()
            except (FileNotFoundError, ProcessLookupError):
                continue
            try:
                fields = data.rsplit(b")", 1)[1].split()
                member_group = int(fields[2])
            except (IndexError, ValueError) as error:
                raise OSError(f"cannot read process state for {entry.name}") from error
            if member_group == pgid and fields[0] not in (b"Z", b"X"):
                return True
        return False

    def finish(self, process):
        try:
            os.killpg(process.pid, signal.SIGTERM)
            deadline = time.monotonic() + .5
            while self.group_alive(process.pid) and time.monotonic() < deadline:
                time.sleep(.01)
            os.killpg(process.pid, signal.SIGKILL)
            deadline = time.monotonic() + 1
            while self.group_alive(process.pid):
                if time.monotonic() >= deadline:
                    raise OSError(f"process group {process.pid} did not stop")
                time.sleep(.01)
        except OSError:
            os.killpg(process.pid, signal.SIGKILL)
            raise
        finally:
            status = process.wait()
            self.processes.remove(process)
        return status

    def cleanup(self):
        error = None
        for process in tuple(self.processes):
            try:
                self.finish(process)
            except OSError as failure:
                error = failure
        if error is not None:
            raise error


def main():
    args = sys.argv[1:]
    if not args:
        jobs = 1
    elif (len(args) == 2 and args[0] == "--jobs"
          and re.fullmatch(r"0*[1-8]", args[1])):
        jobs = int(args[1][-1])
    else:
        print("usage: sh tests/run-unit.sh [--jobs N (1..8)]", file=sys.stderr)
        return 2
    try:
        if sys.platform != "linux" or not all(hasattr(os, name) for name in
                                             ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT")):
            raise OSError("Linux waitid(WNOWAIT) is required")
        Path("/proc/self/stat").read_bytes()
        try:
            os.waitid(os.P_PID, os.getpid(), os.WEXITED | os.WNOHANG | os.WNOWAIT)
        except ChildProcessError:
            pass
    except OSError as error:
        print(f"unit runner: {error}", file=sys.stderr)
        return 2
    for command in ("bend", "sed", "cmp", "diff"):
        if shutil.which(command) is None:
            print(f"unit runner: missing {command}", file=sys.stderr)
            return 2
    inventory = sorted(path for path in Path("tests/unit").glob("*.bend")
                       if not path.name.startswith("."))
    if not inventory:
        print("unit runner: no tests/unit/*.bend files", file=sys.stderr)
        return 2
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    supervisor = Supervisor()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, supervisor.cancel)
    passed = failed = 0
    try:
        with tempfile.TemporaryDirectory(prefix="mailbend-unit-") as directory:
            try:
                for offset in range(0, len(inventory), jobs):
                    batch = []
                    for index, source in enumerate(inventory[offset:offset + jobs], offset):
                        expected = Path(directory) / f"{index}.expected"
                        actual = Path(directory) / f"{index}.actual"
                        with expected.open("wb") as output:
                            extract = supervisor.launch(["sed", "-n", "s/^#|//p", str(source)], stdout=output)
                            if supervisor.wait(extract) != 0:
                                raise OSError(f"cannot extract expectations from {source}")
                        with actual.open("wb") as output:
                            process = supervisor.launch(["bend", str(source)], stdout=output, stderr=subprocess.STDOUT)
                        batch.append(Job(source, expected, actual, process))
                    for job in batch:
                        status = supervisor.wait(job.process)
                        comparison = supervisor.launch(["cmp", "-s", str(job.expected), str(job.actual)])
                        equal = supervisor.wait(comparison)
                        if equal > 1 or equal < 0:
                            raise OSError(f"cannot compare output for {job.source}")
                        if status == 0 and equal == 0:
                            print(f"PASS {job.source}", flush=True)
                            passed += 1
                        else:
                            print(f"FAIL {job.source}", flush=True)
                            difference = Path(directory) / "diff"
                            with difference.open("wb") as output:
                                diff = supervisor.launch(["diff", str(job.expected), str(job.actual)], stdout=output)
                                if supervisor.wait(diff) not in (0, 1):
                                    raise OSError(f"cannot display difference for {job.source}")
                            with difference.open("rb") as output:
                                lines = 0
                                while lines < 20:
                                    supervisor.check()
                                    chunk = output.read(4096)
                                    if not chunk:
                                        break
                                    pieces = chunk.split(b"\n")
                                    remaining = 20 - lines
                                    if len(pieces) > remaining:
                                        chunk = b"\n".join(pieces[:remaining]) + b"\n"
                                    lines += chunk.count(b"\n")
                                    sys.stdout.buffer.write(chunk)
                                sys.stdout.buffer.flush()
                            failed += 1
            finally:
                supervisor.cleanup()
        supervisor.check()
        print(f"unit: {passed} passed, {failed} failed")
        return int(failed != 0)
    except (OSError, ValueError) as error:
        print(f"unit runner: {error}", file=sys.stderr)
        return 128 + supervisor.stop if supervisor.stop else 2


if __name__ == "__main__":
    sys.exit(main())
