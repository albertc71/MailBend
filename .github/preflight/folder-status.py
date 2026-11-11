"""One finite compiler/unit observation, separate from full CI acceptance."""
import hashlib
import os
from pathlib import Path
import resource
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
CANDIDATE = "fcab8d8d25a17018107f3285c619aed40fa5b05b"
CANDIDATE_TREE = "93fabf18628b333f402fe410cfaa4aa89e83d261"
OVERLAY = [".github/preflight/folder-status.py", ".github/workflows/folder-status-preflight.yml"]
LIMIT = 1048576


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def interrupted(signum, frame):
    raise RuntimeError(f"preflight interrupted by signal {signum}")


def limits():
    resource.setrlimit(resource.RLIMIT_FSIZE, (256 * 1024**2, 256 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run(args, seconds, env):
    started = time.monotonic()
    data = bytearray()
    with selectors.DefaultSelector() as selector:
        process = subprocess.Popen(args, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True, preexec_fn=limits)
        try:
            os.set_blocking(process.stdout.fileno(), False)
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline = started + seconds
            while selector.get_map():
                require(time.monotonic() < deadline, f"timeout ({seconds}s): {args}")
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
        identities = run(["git", "rev-parse", "HEAD", "HEAD^{tree}", "HEAD^", CANDIDATE + "^{tree}"], 10, env).decode().splitlines()
        require(len(identities) == 4 and identities[0] == os.environ["EXPECTED_VALIDATION_SHA"], "validation identity mismatch")
        require(identities[2] == CANDIDATE and identities[3] == CANDIDATE_TREE, "candidate parent/tree mismatch")
        changed = run(["git", "diff", "--name-only", "HEAD^", "HEAD"], 10, env).decode().splitlines()
        require(changed == OVERLAY, "validation child changes product paths")
        print(f"validation={identities[0]} tree={identities[1]} candidate={CANDIDATE} candidate_tree={CANDIDATE_TREE}", flush=True)
        run(["sh", "scripts/install-bend.sh"], 90, env)
        require(run(["bend", "version"], 10, env).strip() == b"bend 2.0.35", "unexpected Bend version")
        run(["bend", "src/tools.bend", "--check-only"], 120, env)
        unit = ROOT / "tests/unit/folder-status.bend"
        expected = b"".join(line[2:] + b"\n" for line in unit.read_bytes().splitlines() if line.startswith(b"#|"))
        require(len(expected.splitlines()) == 24, "folder unit golden set changed")
        observed = run(["bend", "tests/unit/folder-status.bend"], 120, env)
        require(observed == expected, f"folder unit golden mismatch: {observed[:4096]!r}")
        output = work / "mailbend-core"
        require(not cuda.exists(), "CUDA exclusion path unexpectedly exists")
        run(["bend", "main.bend", "-o", str(output)], 300, env)
        require(output.is_file() and output.stat().st_size > 0 and os.access(output, os.X_OK), "core compiler did not produce an executable")
        with output.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        print(f"core_sha256={digest} bytes={output.stat().st_size}; binary not executed", flush=True)
    print("PASS exact-candidate compiler and folder unit preflight; temporary files removed; full CI still required", flush=True)


if __name__ == "__main__":
    main()
