"""One finite CPU compiler observation, separate from full CI acceptance."""
import hashlib
import os
from pathlib import Path
import resource
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
CANDIDATE = "fcab8d8d25a17018107f3285c619aed40fa5b05b"
CANDIDATE_TREE = "93fabf18628b333f402fe410cfaa4aa89e83d261"
OVERLAY = [".github/preflight/folder-status.py", ".github/workflows/folder-status-preflight.yml"]
LIMIT = 1048576
DRIVER_SECONDS = 690
CLEANUP_RESERVE = 20


class StageMetadata:
    def __init__(self, directory):
        self.fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.samples = 0
        self.next_sample = time.monotonic()
        self.started = self.next_sample
        self.directory_seen = False
        self.c_seen = False
        self.max_bytes = 0
        self.limited = False

    def stop(self):
        if not self.limited:
            self.limited = True
            print("stage_metadata_limited=1", flush=True)

    def sample(self, initial=False):
        now = time.monotonic()
        if self.limited or (not initial and now < self.next_sample):
            return
        if self.samples >= 601:
            self.stop()
            return
        self.samples += 1
        self.next_sample = now + 1
        directories = 0
        try:
            os.lseek(self.fd, 0, os.SEEK_SET)
            with os.scandir(self.fd) as entries:
                for index, entry in enumerate(entries):
                    if index >= 32:
                        require(not initial, "initial temporary metadata entry limit")
                        self.stop()
                        return
                    if not entry.name.startswith("bend-"):
                        continue
                    require(not initial, "pre-existing compiler temporary directory")
                    if directories >= 4:
                        self.stop()
                        return
                    directories += 1
                    try:
                        child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
                    except FileNotFoundError:
                        continue
                    try:
                        if not self.directory_seen:
                            self.directory_seen = True
                            print(f"stage_directory_seen=1 elapsed_ms={int((now - self.started) * 1000)}", flush=True)
                        try:
                            info = os.stat("mailbend-core.c", dir_fd=child, follow_symlinks=False)
                        except FileNotFoundError:
                            continue
                        if stat.S_ISREG(info.st_mode):
                            self.max_bytes = max(self.max_bytes, info.st_size)
                            if not self.c_seen:
                                self.c_seen = True
                                print(f"stage_c_file_seen=1 elapsed_ms={int((now - self.started) * 1000)} bytes={info.st_size}", flush=True)
                    finally:
                        os.close(child)
        except OSError:
            require(not initial, "initial temporary metadata unavailable")
            self.stop()

    def close(self):
        os.close(self.fd)
        print(f"stage_metadata_samples={self.samples} directory_seen={int(self.directory_seen)} c_seen={int(self.c_seen)} max_c_bytes={self.max_bytes} limited={int(self.limited)}", flush=True)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def interrupted(signum, frame):
    raise RuntimeError(f"preflight interrupted by signal {signum}")


def limits():
    resource.setrlimit(resource.RLIMIT_FSIZE, (256 * 1024**2, 256 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run(args, seconds, env, driver_deadline, observer=None):
    started = time.monotonic()
    deadline = min(started + seconds, driver_deadline - CLEANUP_RESERVE)
    require(deadline > started, "driver cleanup reserve reached")
    data = bytearray()
    with selectors.DefaultSelector() as selector:
        process = subprocess.Popen(args, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True, preexec_fn=limits)
        try:
            os.set_blocking(process.stdout.fileno(), False)
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                require(time.monotonic() < deadline, f"deadline reached (command cap {seconds}s, driver reserve {CLEANUP_RESERVE}s): {args}")
                if observer is not None:
                    observer.sample()
                for key, _ in selector.select(timeout=min(0.05, max(0, deadline - time.monotonic()))):
                    block = os.read(key.fd, min(65536, LIMIT + 1 - len(data)))
                    if not block:
                        selector.unregister(key.fileobj)
                    else:
                        data.extend(block)
                        require(len(data) <= LIMIT, f"combined output exceeded {LIMIT} bytes: {args}")
            code = process.wait(timeout=max(0, deadline - time.monotonic()))
            if code != 0:
                raise RuntimeError(f"command exited {code}: {args}")
            print(f"PASS {args}: {time.monotonic() - started:.3f}s, {len(data)} captured bytes", flush=True)
            return bytes(data)
        except BaseException:
            if data:
                sys.stdout.buffer.write(data[:LIMIT])
                sys.stdout.buffer.flush()
            raise
        finally:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            process.stdout.close()


def main():
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGALRM, interrupted)
    driver_deadline = time.monotonic() + DRIVER_SECONDS
    signal.setitimer(signal.ITIMER_REAL, DRIVER_SECONDS)
    with tempfile.TemporaryDirectory(prefix="folder-status-preflight-", dir=os.environ["RUNNER_TEMP"]) as directory:
        work = Path(directory)
        home = work / "home"
        temp = work / "tmp"
        cuda = work / "disabled-cuda"
        home.mkdir()
        temp.mkdir()
        env = {"HOME": str(home), "TMPDIR": str(temp), "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
               "PATH": str(home / ".bend/bin") + ":/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
               "BEND_NO_TELEMETRY": "1", "GIT_CONFIG_NOSYSTEM": "1", "CUDA_HOME": str(cuda)}
        require(shutil.which("clang", path=env["PATH"]) is not None, "standard runner lacks clang")
        identities = run(["git", "rev-parse", "HEAD", "HEAD^{tree}", "HEAD^", CANDIDATE + "^{tree}"], 10, env, driver_deadline).decode().splitlines()
        require(len(identities) == 4 and identities[0] == os.environ["EXPECTED_VALIDATION_SHA"], "validation identity mismatch")
        require(identities[2] == CANDIDATE and identities[3] == CANDIDATE_TREE, "candidate parent/tree mismatch")
        changed = run(["git", "diff", "--name-only", "HEAD^", "HEAD"], 10, env, driver_deadline).decode().splitlines()
        require(changed == OVERLAY, "validation child changes product paths")
        print(f"validation={identities[0]} tree={identities[1]} candidate={CANDIDATE} candidate_tree={CANDIDATE_TREE}", flush=True)
        run(["sh", "scripts/install-bend.sh"], 90, env, driver_deadline)
        require(run(["bend", "version"], 10, env, driver_deadline).strip() == b"bend 2.0.35", "unexpected Bend version")
        output = work / "mailbend-core"
        require(not cuda.exists(), "CUDA exclusion path unexpectedly exists")
        observer = StageMetadata(temp)
        try:
            observer.sample(initial=True)
            run(["bend", "main.bend", "-o", str(output)], 600, env, driver_deadline, observer)
        finally:
            observer.close()
        require(output.is_file() and output.stat().st_size > 0 and os.access(output, os.X_OK), "core compiler did not produce an executable")
        with output.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        print(f"core_sha256={digest} bytes={output.stat().st_size}; binary not executed", flush=True)
    require(time.monotonic() < driver_deadline, "whole-driver deadline reached")
    signal.setitimer(signal.ITIMER_REAL, 0)
    print("PASS exact-candidate CPU compilation observation; temporary files removed; full CI still required", flush=True)


if __name__ == "__main__":
    main()
