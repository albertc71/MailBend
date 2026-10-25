#!/usr/bin/env python3
import os
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPERS = ("mailbend-tls", "mailbend-attach", "mailbend-typesafe", "mailbend-stdio")
TARGETS = HELPERS + ("mailbend-core",)
NEW_HELPER = b"#!/bin/sh\nexit 0\n"
NEW_CORE = b"#!/bin/sh\necho NEW_CORE\n"
TOOL = r'''#!/usr/bin/python3
import os, sys

def bump():
    fd = os.open(os.environ["INSTALL_SWAP_COUNT"], os.O_RDWR)
    import fcntl
    fcntl.flock(fd, fcntl.LOCK_EX)
    raw = os.read(fd, 64) or b"0"
    n = int(raw) + 1
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, str(n).encode())
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)
    return n

def executed(path):
    try:
        inode = os.stat(path).st_ino
    except OSError:
        return False
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            if os.stat("/proc/" + entry + "/exe").st_ino == inode:
                return True
        except OSError:
            pass
    return False

def note(path):
    with open(os.environ["INSTALL_SWAP_LOG"], "a", encoding="utf-8") as handle:
        handle.write("write-open %s\n" % path)

def fail_here(n):
    want = int(os.environ.get("INSTALL_SWAP_FAIL_AT") or "0")
    return want != 0 and n == want

def write_partial(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o755)
    os.write(fd, data[: max(1, len(data) // 2)])
    os.close(fd)

name = os.path.basename(sys.argv[0])
how = os.environ.get("INSTALL_SWAP_FAIL_HOW") or "before"
if name == "cp":
    src, dest = sys.argv[1], sys.argv[2]
    n = bump()
    if executed(dest):
        note(dest)
        sys.exit(1)
    if fail_here(n) and how == "before":
        sys.exit(1)
    if fail_here(n) and how == "partial":
        write_partial(dest, open(src, "rb").read())
        sys.exit(1)
    os.execv(os.environ["INSTALL_SWAP_CP"], [os.environ["INSTALL_SWAP_CP"], src, dest])
if name == "mv":
    src, dest = sys.argv[2], sys.argv[3]
    n = bump()
    if fail_here(n):
        sys.exit(1)
    os.execv(os.environ["INSTALL_SWAP_MV"], [os.environ["INSTALL_SWAP_MV"], "-f", src, dest])
if name == "bend":
    if sys.argv[1:] == ["PROOF.bend"]:
        sys.exit(0)
    if len(sys.argv) == 4 and sys.argv[1] == "main.bend" and sys.argv[2] == "-o":
        dest = sys.argv[3]
        n = bump()
        if os.environ.get("INSTALL_SWAP_BEND_DOWN") == "1":
            sys.exit(1)
        if fail_here(n) and how == "before":
            sys.exit(1)
        if executed(dest):
            os.unlink(dest)
        if fail_here(n) and how == "partial":
            write_partial(dest, b"#!/bin/sh\necho NEW_CORE\n")
            sys.exit(1)
        fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o755)
        os.write(fd, b"#!/bin/sh\necho NEW_CORE\n")
        os.close(fd)
        os.chmod(dest, 0o755)
        sys.exit(0)
    sys.exit("unexpected bend args")
sys.exit("unexpected tool")
'''


class SwapFailure(Exception):
    pass


def classify(files, old, new, extras, violations):
    if violations:
        raise SwapFailure("opened a running executable for writing: " + violations)
    if extras:
        raise SwapFailure("temp files remain: " + " ".join(extras))
    for name in TARGETS:
        data = files.get(name)
        if data is None:
            raise SwapFailure(name + " is missing")
        if data != old[name] and data != new[name]:
            raise SwapFailure(name + " is neither the old file nor the new file")


def prove_oracle():
    old = {name: b"old-" + name.encode() for name in TARGETS}
    new = {name: b"new-" + name.encode() for name in TARGETS}
    files = dict(old)
    files["mailbend-stdio"] = b"trunc"
    try:
        classify(files, old, new, [], "")
    except SwapFailure as error:
        if "neither" not in str(error):
            raise SystemExit("checker rejected truncation for the wrong reason: " + str(error))
        return
    raise SystemExit("checker accepted a truncated file")


def executable(path, text):
    path.write_text("#!/bin/sh\n" + text)
    path.chmod(0o755)


def stage(root, count_path, log_path, fail_at, how, bend_down):
    tools = root / "tools"
    tools.mkdir()
    (root / "native").mkdir()
    (root / "scripts").mkdir()
    (root / "bin").mkdir()
    shutil.copy2(ROOT / "scripts/install.sh", root / "scripts/install.sh")
    for command in ("dirname", "sed", "mkdir", "rm"):
        (tools / command).symlink_to(shutil.which(command))
    tool = tools / "swap-tool.py"
    tool.write_text(TOOL)
    tool.chmod(0o755)
    for command in ("cp", "mv", "bend"):
        (tools / command).symlink_to(tool)
    executable(tools / "cc", "exit 0\n")
    executable(tools / "clang", "exit 0\n")
    executable(tools / "rustc", "echo 'rustc 1.99.0'\n")
    executable(tools / "cargo", """if [ "$1" = --version ]; then
  echo 'cargo 1.99.0'
  exit 0
fi
/bin/mkdir -p target/release
for name in mailbend-tls mailbend-attach mailbend-typesafe mailbend-stdio; do
  printf '#!/bin/sh\\nexit 0\\n' > "target/release/$name"
  /bin/chmod +x "target/release/$name"
done
""")
    sleep = pathlib.Path(shutil.which("sleep"))
    if sleep.read_bytes()[:4] != b"\x7fELF":
        raise SystemExit("sleep is not an ELF, so ETXTBSY cannot be observed")
    old = {}
    for name in HELPERS:
        if name == "mailbend-stdio":
            shutil.copy2(sleep, root / "bin" / name)
        else:
            (root / "bin" / name).write_bytes(("old-" + name + "\n").encode())
        old[name] = (root / "bin" / name).read_bytes()
    shutil.copy2(sleep, root / "bin/mailbend-core")
    old["mailbend-core"] = (root / "bin/mailbend-core").read_bytes()
    held = [
        subprocess.Popen([str(root / "bin/mailbend-stdio"), "120"]),
        subprocess.Popen([str(root / "bin/mailbend-core"), "120"]),
    ]
    count_path.write_text("0")
    log_path.write_text("")
    env = {
        "PATH": str(tools),
        "HOME": str(root),
        "LANG": "C",
        "INSTALL_SWAP_COUNT": str(count_path),
        "INSTALL_SWAP_LOG": str(log_path),
        "INSTALL_SWAP_FAIL_AT": str(fail_at),
        "INSTALL_SWAP_FAIL_HOW": how,
        "INSTALL_SWAP_BEND_DOWN": "1" if bend_down else "0",
        "INSTALL_SWAP_CP": shutil.which("cp"),
        "INSTALL_SWAP_MV": shutil.which("mv"),
    }
    return old, held, env


def snapshot(root, held):
    files = {}
    for path in (root / "bin").iterdir():
        files[path.name] = path.read_bytes()
    extras = sorted(set(files) - set(TARGETS))
    alive = all(proc.poll() is None for proc in held)
    return files, extras, alive


def run(fail_at, how, bend_down=False):
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        count_path = root / "count"
        log_path = root / "log"
        old, held, env = stage(root, count_path, log_path, fail_at, how, bend_down)
        try:
            proc = subprocess.run(
                ["/bin/sh", str(root / "scripts/install.sh")],
                env=env,
                capture_output=True,
                timeout=15,
            )
            files, extras, alive = snapshot(root, held)
            violations = log_path.read_text(encoding="utf-8")
            steps = int(count_path.read_text() or "0")
        finally:
            for proc_held in held:
                if proc_held.poll() is None:
                    proc_held.kill()
                proc_held.wait(timeout=5)
        return proc, old, files, extras, alive, violations, steps


def main():
    prove_oracle()
    new = {name: NEW_HELPER for name in HELPERS}
    new["mailbend-core"] = NEW_CORE
    proc, old, files, extras, alive, violations, steps = run(0, "before")
    if proc.returncode != 0 or not alive:
        raise SystemExit(
            "install failed while binaries were executing\n"
            + proc.stdout.decode()
            + proc.stderr.decode()
        )
    classify(files, old, new, extras, violations)
    for name in TARGETS:
        if files[name] != new[name]:
            raise SystemExit(name + " was not replaced")
    injected = 0
    for how in ("before", "partial"):
        for fail_at in range(1, steps + 1):
            proc, old, files, extras, alive, violations, _used = run(fail_at, how)
            injected += 1
            if not alive:
                raise SystemExit("running binary died at %s step %s" % (how, fail_at))
            try:
                classify(files, old, new, extras, violations)
            except SwapFailure as error:
                raise SystemExit("%s step %s: %s" % (how, fail_at, error)) from error
    proc, old, files, extras, alive, violations, _used = run(0, "before", bend_down=True)
    injected += 1
    if proc.returncode == 0:
        raise SystemExit("bend failure did not fail the install")
    if not alive:
        raise SystemExit("running binary died when bend failed")
    try:
        classify(files, old, new, extras, violations)
    except SwapFailure as error:
        raise SystemExit("bend failure: " + str(error)) from error
    for name in HELPERS:
        if files[name] != new[name]:
            raise SystemExit(name + " was not published before the bend failure")
    if files["mailbend-core"] != old["mailbend-core"]:
        raise SystemExit("core changed even though bend failed")
    print("install swap: %s publish steps, %s injected failures, properties hold" % (steps, injected))


if __name__ == "__main__":
    main()
