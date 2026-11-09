import hashlib, json, os, selectors, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path
CAP = 1024 * 1024
CANCELLED = False
HERE = Path(__file__).resolve().parent
INPUTS = json.loads((HERE / "inputs.json").read_text())
EXTRAS = {".github/workflows/webde-resources.yml", "tests/validation/webde-resources/driver.py", "tests/validation/webde-resources/inputs.json"}
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

def verify(root, extras=False):
    expected = {r["path"]: r for r in INPUTS["files"]}
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
            if relative != ".git": found.add(relative)
    if found != set(expected) | (EXTRAS if extras else set()):
        raise Infrastructure("path-inventory")
    for relative, row in expected.items():
        f = root / relative
        b = os.fsencode(os.readlink(f)) if f.is_symlink() else f.read_bytes()
        mode = "120000" if f.is_symlink() else "100755" if f.stat().st_mode & 0o111 else "100644"
        blob = hashlib.sha1(b"blob " + str(len(b)).encode() + b"\0" + b).hexdigest()
        if mode != row["mode"] or blob != row["sha"]:
            raise Infrastructure("source-identity")
    receipt("source", product=INPUTS["product"], tree=INPUTS["tree"], entries=len(expected))

def main():
    if (os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_RUN_ATTEMPT") != "1"
            or os.environ.get("GITHUB_EVENT_NAME") != "push"
            or os.environ.get("GITHUB_REF") != "refs/heads/validation/webde-165-resources-20261109"):
        raise Infrastructure("admission")
    deadline = time.monotonic() + 2400
    checkout = HERE.parents[2]
    verify(checkout, extras=True)
    receipt("inputs", inventory_sha256=digest((HERE / "inputs.json").read_bytes()),
            driver_sha256=digest(Path(__file__).read_bytes()))
    with tempfile.TemporaryDirectory(prefix="webde-resources-", dir=os.environ["RUNNER_TEMP"]) as directory:
        work = Path(directory)
        root, home, tmp = work / "source", work / "home", work / "tmp"
        home.mkdir(); tmp.mkdir(); root.mkdir()
        for row in INPUTS["files"]:
            src, dst = checkout / row["path"], root / row["path"]
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_symlink(): dst.symlink_to(os.readlink(src))
            else: shutil.copy2(src, dst)
        verify(root)
        env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(tmp), "LANG": "C.UTF-8",
               "BEND_NO_TELEMETRY": "1", "PYTHONDONTWRITEBYTECODE": "1", "PIP_NO_CACHE_DIR": "1",
               "PYTHONUSERBASE": str(home / "python")}
        required([sys.executable, "-m", "pip", "install", "--user", "--no-cache-dir", "jsonschema==4.26.0"], root, env, 120, "schema-dependency", deadline)
        required(["sh", "scripts/install-rust.sh"], root, env, 180, "pinned-rust", deadline)
        required(["sh", "scripts/install-bend.sh"], root, env, 180, "pinned-bend", deadline)
        env["PATH"] = str(home / ".cargo/bin") + os.pathsep + str(home / ".bend/bin") + os.pathsep + env["PATH"]
        for argv, cwd, name in ((["cargo", "--version"], root / "native", "cargo-version"),
                                (["rustc", "--version"], root / "native", "rustc-version"),
                                (["bend", "version"], root, "bend-version"),
                                (["clang", "--version"], root, "clang-version")):
            required(argv, cwd, env, 10, name, deadline)
        required(["cargo", "build", "--release", "--locked", "--quiet", "-p", "mailbend-tls", "-p", "mailbend-attach", "-p", "mailbend-typesafe", "-p", "mailbend-stdio"], root / "native", env, 600, "native-build", deadline)
        (root / "bin").mkdir(exist_ok=True)
        for name in ("mailbend-tls", "mailbend-attach", "mailbend-typesafe", "mailbend-stdio"):
            dst = root / "bin" / name
            if dst.exists(): raise Infrastructure("preexisting-native")
            shutil.copy2(root / "native/target/release" / name, dst)
            receipt("native", name=name, sha256=digest(dst.read_bytes()))
        for name in ("mailbend-tls", "mailbend-typesafe", "mailbend-stdio"):
            required([str(root / "bin" / name), "--check"], root, env, 30, name + "-check", deadline)
        core = root / "bin/mailbend-core"
        if core.exists(): raise Infrastructure("preexisting-core")
        required(["bend", "main.bend", "-o", str(core)], root, env, 900, "core-build-once", deadline)
        receipt("core", sha256=digest(core.read_bytes()))
        _, out, err = required([sys.executable, "tests/test-mime-corpus.py", "--nested-resources"], root, env, 900, "full-corpus-nested-resources", deadline)
        if b"MIME checks: 0 failed;" not in out:
            raise Infrastructure("corpus-summary-missing")
        receipt("gate", full_corpus=True, nested_resources=True, harness_transitive=True, result="pass")

if __name__ == "__main__":
    def interrupted(signum, frame):
        global CANCELLED
        CANCELLED = True
    signal.signal(signal.SIGTERM, interrupted); signal.signal(signal.SIGINT, interrupted)
    try: main()
    except BaseException as error:
        receipt("result", status="incomplete-or-failed", reason=str(error) if isinstance(error, Infrastructure) else type(error).__name__)
        sys.exit(1)
    receipt("result", status="pass")
