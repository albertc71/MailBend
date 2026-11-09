"""Proposed hosted-only evidence driver. No provider connection is required."""
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
INPUTS = json.loads((HERE / "inputs.json").read_text())
EXTRAS = {".github/workflows/webde-measurement.yml",
          "tests/validation/webde-measurement/driver.py", "tests/validation/webde-measurement/inputs.json"}
CAP = 1024 * 1024
CANCELLED = False

class Infrastructure(Exception):
    pass

def digest(data):
    return hashlib.sha256(data).hexdigest()

def receipt(kind, **fields):
    line = json.dumps({"kind": kind, **fields}, sort_keys=True)
    if len(line.encode()) > CAP:
        raise Infrastructure("receipt-cap")
    print(line, flush=True)

def command(argv, cwd, env, seconds, label, deadline=None):
    started = time.monotonic()
    if CANCELLED:
        raise Infrastructure("interrupted")
    if deadline is not None:
        seconds = min(seconds, deadline - time.monotonic())
    if seconds <= 0:
        raise Infrastructure(label + "-deadline")
    process = None
    selector = None
    buffers = {"out": bytearray(), "err": bytearray()}
    failed = None
    code = None
    try:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        selector = selectors.DefaultSelector()
        for stream, name in ((process.stdout, "out"), (process.stderr, "err")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        end = time.monotonic() + seconds
        if deadline is not None:
            end = min(end, deadline)
        while selector.get_map():
            if CANCELLED:
                raise Infrastructure("interrupted")
            if time.monotonic() >= end:
                raise Infrastructure(label + "-timeout")
            for key, _ in selector.select(min(.1, max(0, end - time.monotonic()))):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buffers[key.data].extend(chunk)
                if sum(map(len, buffers.values())) > CAP:
                    raise Infrastructure(label + "-output-cap")
        while os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
            if CANCELLED:
                raise Infrastructure("interrupted")
            if time.monotonic() >= end:
                raise Infrastructure(label + "-timeout")
            time.sleep(.02)
    except BaseException as error:
        failed = error
    finally:
        try:
            if selector is not None:
                selector.close()
        finally:
            if process is not None:
                try:
                    for sig in (signal.SIGTERM, signal.SIGKILL):
                        try:
                            os.killpg(process.pid, sig)
                        except ProcessLookupError:
                            pass
                    try:
                        code = process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        raise Infrastructure(label + "-cleanup-timeout") from None
                finally:
                    for stream in (process.stdout, process.stderr):
                        if stream is not None:
                            stream.close()
    out, err = bytes(buffers["out"]), bytes(buffers["err"])
    receipt("command", name=label, argv_sha256=digest(json.dumps(argv).encode()), exit=code, elapsed_seconds=round(time.monotonic() - started, 6),
            stdout_bytes=len(out), stderr_bytes=len(err),
            stdout_sha256=digest(out), stderr_sha256=digest(err))
    if failed:
        raise failed
    if CANCELLED:
        raise Infrastructure("interrupted")
    return code, out, err

def required(argv, cwd, env, seconds, label, deadline=None):
    result = command(argv, cwd, env, seconds, label, deadline)
    if result[0] != 0:
        raise Infrastructure(label + "-nonzero")
    return result

def source_bytes(path):
    return os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()

def verify_export(root, label, allow_extras=False):
    expected = INPUTS["trees"][label]["files"]
    found = set()
    for base, dirs, files in os.walk(root, followlinks=False):
        if Path(base) == root and ".git" in dirs:
            dirs.remove(".git")
        for name in list(dirs):
            if (Path(base) / name).is_symlink():
                dirs.remove(name)
                files.append(name)
        for name in files:
            relative = (Path(base) / name).relative_to(root).as_posix()
            if relative == ".git":
                continue
            found.add(relative)
    if found != set(expected) | (EXTRAS if allow_extras else set()):
        raise Infrastructure(label + "-path-inventory")
    for relative, row in expected.items():
        path = root / relative
        mode = "120000" if path.is_symlink() else "100755" if path.stat().st_mode & 0o111 else "100644"
        if mode != row["mode"] or digest(source_bytes(path)) != row["sha256"]:
            raise Infrastructure(label + "-source-identity")
    receipt("source", side=label, entries=len(expected), tree=INPUTS["trees"][label]["tree_sha"])

def copy_product(source, target, label):
    for relative in INPUTS["trees"][label]["files"]:
        src, dst = source / relative, target / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        if src.is_symlink():
            dst.symlink_to(os.readlink(src))
        else:
            shutil.copy2(src, dst)
    verify_export(target, label)

def compiler_identity(root, env, deadline):
    selected = shutil.which("clang", path=env["PATH"])
    if selected is None:
        raise Infrastructure("clang-missing")
    cc = str(Path(selected).resolve(strict=True))
    _, out, err = required([cc, "--version"], root, env, 10, "clang-version", deadline)
    version = re.search(rb"(?:\w+ )?clang version (\d+)", out)
    if version is None or int(version.group(1)) < 14:
        raise Infrastructure("unsupported-clang")
    receipt("compiler", realpath=cc, executable_sha256=digest(Path(cc).read_bytes()),
            version_sha256=digest(out + err))
    return cc

def main():
    if (os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("WEBDE_RUN_ATTEMPT") != "1"
            or os.environ.get("GITHUB_EVENT_NAME") != "push"
            or os.environ.get("GITHUB_REF") != "refs/heads/validation/webde-165-measure-20261109"
            or os.environ.get("WEBDE_PRODUCT") != "124dfcda14d270ff25888f0c507eda2d73adc08b"):
        raise Infrastructure("execution-admission")
    deadline = time.monotonic() + 1200
    checkout = HERE.parents[2]
    verify_export(checkout, "candidate", allow_extras=True)
    receipt("measurement-input", product=INPUTS["product_commit"],
            driver_sha256=digest(Path(__file__).read_bytes()),
            inventory_sha256=digest((HERE / "inputs.json").read_bytes()))
    with tempfile.TemporaryDirectory(prefix="webde-measure-", dir=os.environ["RUNNER_TEMP"]) as directory:
        work = Path(directory)
        home, tmp, root = work / "home", work / "tmp", work / "source"
        home.mkdir()
        tmp.mkdir()
        env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(tmp),
               "LANG": "C.UTF-8", "BEND_NO_TELEMETRY": "1", "PYTHONDONTWRITEBYTECODE": "1"}
        copy_product(checkout, root, "candidate")
        cc = compiler_identity(root, env, deadline)
        required(["sh", "scripts/install-bend.sh"], root, env, 120, "pinned-bend-bootstrap", deadline)
        env["PATH"] = str(home / ".bend/bin") + os.pathsep + env["PATH"]
        required(["bend", "version"], root, env, 10, "bend-version", deadline)
        (root / "bin").mkdir(exist_ok=True)
        generated = root / "bin/mailbend-measure.c"
        if generated.exists():
            raise Infrastructure("preexisting-emission")
        required(["bend", "main.bend", "-o", str(generated)], root, env, 480, "emit-c", deadline)
        code = generated.read_bytes()
        c_hash = digest(code)
        if (not re.search(rb"^#define BANGS\s+0$", code, re.M)
                or b"#import" in code or b"#include <X11/" in code or b"#include <alsa/" in code):
            raise Infrastructure("unexpected-native-requirements")
        receipt("emission", c_sha256=c_hash, bytes=len(code))
        for level, limit in (("O3", 480), ("O0", 120)):
            core = root / ("bin/mailbend-measure-" + level)
            if core.exists() or digest(generated.read_bytes()) != c_hash:
                raise Infrastructure("build-input-drift")
            required([cc, "-std=c11", "-" + level, str(generated), "-lpthread", "-lm",
                      "-o", str(core)], root, env, limit, "compile-native-" + level, deadline)
            if not core.is_file() or not os.access(core, os.X_OK):
                raise Infrastructure("compiled-core-missing")
            receipt("measurement-binary", optimization=level, c_sha256=c_hash,
                    core_sha256=digest(core.read_bytes()), bytes=core.stat().st_size)
        if digest(generated.read_bytes()) != c_hash:
            raise Infrastructure("final-emission-drift")
        receipt("measurement-complete", product=INPUTS["product_commit"], c_sha256=c_hash,
                binaries_executed=False)

if __name__ == "__main__":
    def interrupted(signum, frame):
        global CANCELLED
        CANCELLED = True
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        main()
    except BaseException as error:
        code = str(error) if isinstance(error, Infrastructure) else type(error).__name__
        receipt("result", status="incomplete-or-failed", reason=code)
        sys.exit(1)
    receipt("result", status="pass")
