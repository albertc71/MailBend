#!/usr/bin/env python3
"""Fixed synthetic controls for the survived-signal output contract."""
import hashlib
import importlib.util
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import traceback
import time
import unittest

TEST = "test_survived_signal_preserves_later_failure_without_waiting_for_output"
WAIT_LINE = "self.assertEqual(session.proc.wait(timeout=10), 3)"
PREFIX_LINE = "self.assertEqual(received, (self.PATTERN * 1024)[:len(received)])"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def replace_once(source, old, new):
    require(source.count(old) == 1, f"mutation anchor count for {old!r}")
    return source.replace(old, new, 1)


class Capture(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.observed = []

    def addError(self, test, error):
        self.observed.append(("error", error[0], error[1],
                              traceback.extract_tb(error[2])))
        super().addError(test, error)

    def addFailure(self, test, error):
        self.observed.append(("failure", error[0], error[1],
                              traceback.extract_tb(error[2])))
        super().addFailure(test, error)


def single(root, mode):
    sys.path.insert(0, str(root / "tests"))
    case = runpy.run_path(str(root / "tests/test-stdio.py"))["OutputRelayTests"]
    if mode == "wrong-status":
        case.CORE = replace_once(case.CORE, "    os._exit(3)\n", "    os._exit(4)\n")
    elif mode == "corrupt-prefix":
        case.CORE = replace_once(
            case.CORE,
            '    sys.stdout.buffer.write(b"0123456789abcdef" * 1024)\n',
            '    sys.stdout.buffer.write(b"X123456789abcdef" * 1024)\n')
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(case) if mode == "suite" else unittest.TestSuite([case(TEST)])
    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=2, resultclass=Capture).run(suite)
    require(not result.skipped and not result.expectedFailures and not result.unexpectedSuccesses,
            f"{mode}: skipped or exceptional result")
    if mode in ("suite", "positive"):
        require(result.wasSuccessful(), f"{mode}: positive control failed")
        require(result.testsRun == (9 if mode == "suite" else 1), f"{mode}: wrong test count")
    else:
        require(result.testsRun == 1 and len(result.observed) == 1,
                f"{mode}: expected exactly one observed failure")
        kind, error_type, error, frames = result.observed[0]
        target = PREFIX_LINE if mode == "corrupt-prefix" else WAIT_LINE
        require(any(frame.name == TEST and frame.line == target for frame in frames),
                f"{mode}: failed outside the intended assertion")
        if mode == "nonsticky-signal":
            require(kind == "error" and error_type is subprocess.TimeoutExpired and error.timeout == 10,
                    f"{mode}: expected final pre-read wait timeout, got {error_type.__name__}: {error}")
        else:
            require(kind == "failure" and error_type is AssertionError,
                    f"{mode}: expected assertion mismatch, got {error_type.__name__}: {error}")
            if mode == "wrong-status":
                require(str(error) == "4 != 3", f"{mode}: wrong status mismatch: {error}")
    print(f"CONTROL ACCEPTED {mode}: tests={result.testsRun} failures={len(result.failures)} errors={len(result.errors)}",
          flush=True)


def main(root):
    comparison_spec = importlib.util.spec_from_file_location(
        "comparison_cleanup", root / "tests/compare-mcp-schema.py")
    cleanup = importlib.util.module_from_spec(comparison_spec)
    comparison_spec.loader.exec_module(cleanup)
    cleanup.enable_subreaper()

    def execute(command, label, timeout, cwd):
        proc = subprocess.Popen(
            command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, start_new_session=True)
        try:
            output, _ = proc.communicate(timeout=timeout)
        except BaseException as error:
            if isinstance(error, subprocess.TimeoutExpired) and error.output:
                partial = error.output
                print(partial.decode(errors="replace") if isinstance(partial, bytes) else partial,
                      end="", flush=True)
            cleanup.reap_timeout(proc)
            raise
        print(output, end="", flush=True)
        deadline = time.monotonic() + 10
        while remaining := cleanup.descendants(os.getpid()):
            live = []
            for pid in remaining:
                identity = cleanup.process_identity(pid)
                if identity is not None and identity[1] not in ("Z", "X"):
                    live.append(pid)
                else:
                    try:
                        os.waitpid(pid, os.WNOHANG)
                    except ChildProcessError:
                        pass
            if not live:
                break
            if time.monotonic() >= deadline:
                cleanup.reap_timeout(proc)
                raise RuntimeError(f"{label}: descendants did not finish: {live}")
            time.sleep(0.01)
        require(proc.returncode == 0, f"{label}: driver exit {proc.returncode}")

    def run(mode):
        execute([sys.executable, str(Path(__file__).resolve()), str(root), "--single", mode],
                mode, 120, root)

    def build():
        execute(["cargo", "build", "--release", "--locked", "-p", "mailbend-stdio"],
                "build", 300, root / "native")
        (root / "bin").mkdir(exist_ok=True)
        shutil.copy2(root / "native/target/release/mailbend-stdio", root / "bin/mailbend-stdio")

    paths = [root / "tests/test-stdio.py", root / "native/mailbend-stdio/src/relay.rs"]
    originals = {path: path.read_bytes() for path in paths}
    for path, data in originals.items():
        print(f"SOURCE {path.relative_to(root)} {hashlib.sha256(data).hexdigest()}", flush=True)
    build()
    run("suite")
    for trial in range(1, 4):
        print(f"FIXED POSITIVE TRIAL {trial}/3", flush=True)
        run("positive")
    run("wrong-status")
    run("corrupt-prefix")
    relay = paths[1]
    try:
        relay.write_text(replace_once(
            originals[relay].decode(),
            "            stopping |= forwarded.is_some();",
            "            stopping = forwarded.is_some();"))
        build()
        run("nonsticky-signal")
    finally:
        relay.write_bytes(originals[relay])
    build()
    run("suite")
    for path, data in originals.items():
        require(path.read_bytes() == data, f"source not restored: {path}")
    subprocess.run(["git", "diff", "--exit-code"], cwd=root, check=True)
    print("ALL FIXED STDIO CONTROLS PASSED; PRODUCT SOURCES RESTORED", flush=True)


if __name__ == "__main__":
    root = Path(sys.argv[1]).resolve()
    if len(sys.argv) == 4 and sys.argv[2] == "--single":
        single(root, sys.argv[3])
    elif len(sys.argv) == 2:
        main(root)
    else:
        sys.exit("expected product path and optional --single mode")
