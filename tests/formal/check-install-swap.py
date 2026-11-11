#!/usr/bin/env python3
"""Bounded public-command crash oracle. Disposable synthetic data only."""
import hashlib
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
MEMBERS = ("mailbend-core", "mailbend-tls", "mailbend-attach",
           "mailbend-typesafe", "mailbend-stdio")
B = {"mailbend-core": b"#!/bin/sh\necho B-mailbend-core\n",
     "mailbend-tls": b"#!/bin/sh\necho B-mailbend-tls\n",
     "mailbend-attach": b"#!/bin/sh\necho B-mailbend-attach\n",
     "mailbend-typesafe": b"#!/bin/sh\necho B-mailbend-typesafe\n",
     "mailbend-stdio": b"#!/bin/sh\necho B-mailbend-stdio\n"}
COMMANDS = ("cp", "mv", "sync", "chmod", "mkdir", "ln", "rmdir")
DEADLINE = None
TOOL = r"""
import json, os, pathlib, signal, sys
root = pathlib.Path(os.environ["FAULT_ROOT"])
command = pathlib.Path(sys.argv[0]).name
if command == "cargo" and sys.argv[1:] == ["--version"]:
    print("cargo 1.99.0")
    sys.exit(0)
count = root / "count"
index = int(count.read_text()) + 1
count.write_text(str(index))
event = {"index": index, "command": command, "args": sys.argv[1:]}
with (root / "events").open("a") as handle:
    handle.write(json.dumps(event) + "\n")
wanted = int(os.environ.get("FAULT_AT", "0"))
how = os.environ.get("FAULT_HOW", "before")
if index == wanted and how == "before":
    sys.exit(81)
if index == wanted and how == "disk-full":
    import errno
    if command != "cp" or len(sys.argv) != 3:
        sys.exit("disk-full injection only supports the staged copy boundary")
    destination = pathlib.Path(sys.argv[2])
    if root not in destination.parents:
        sys.exit("fault destination escaped disposable fixture")
    destination.write_bytes(pathlib.Path(sys.argv[1]).read_bytes()[:7])
    raise OSError(errno.ENOSPC, "synthetic staging write exhausted")
if command == "cargo":
    if sys.argv[1:5] != ["build", "--release", "--locked", "--quiet"]:
        sys.exit("unexpected cargo invocation")
    status = 0
elif command == "bend":
    if sys.argv[1:] == ["PROOF.bend"]:
        status = 0
    elif len(sys.argv) == 4 and sys.argv[1:3] == ["main.bend", "-o"]:
        path = pathlib.Path(sys.argv[3])
        path.write_bytes(b"#!/bin/sh\necho B-mailbend-core\n")
        path.chmod(0o755)
        status = 0
    else:
        sys.exit("unexpected Bend invocation")
else:
    import subprocess
    if command == "sync" and pathlib.Path(sys.argv[-1]).name == "FORMAT":
        if pathlib.Path(sys.argv[-1]).stat().st_mode & 0o7777 != 0o644:
            sys.exit("FORMAT must have final mode before its flush")
    actual = json.loads(os.environ["FAULT_COMMANDS"])[command]
    status = subprocess.run([actual, *sys.argv[1:]], timeout=5).returncode
if status:
    sys.exit(status)
if index == wanted:
    if how == "kill-after":
        os.killpg(os.getpgrp(), signal.SIGKILL)
    sys.exit(82)
sys.exit(0)
"""


def write_executable(path, data):
    path.write_bytes(data)
    path.chmod(0o755)


def fixture(root, phase):
    tools = root / "tools"
    tools.mkdir()
    (root / "scripts").mkdir()
    (root / "native/target/release").mkdir(parents=True)
    for name in ("install.sh", "install-layout.sh"):
        shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
    for name in ("dirname", "sed", "rm", "flock", "stat", "id", "head",
                 "readlink", "mktemp", "sha256sum"):
        (tools / name).symlink_to(shutil.which(name))
    script = ("#!" + sys.executable + "\n" + TOOL).encode()
    for name in (*COMMANDS, "bend", "cargo"):
        write_executable(tools / name, script)
    for name, body in (("cc", "exit 0"), ("clang", "exit 0"),
                       ("getconf", "echo 'glibc 2.34'"), ("rustc", "echo 'rustc 1.99.0'")):
        write_executable(tools / name, ("#!/bin/sh\n" + body + "\n").encode())
    for name in MEMBERS[1:]:
        write_executable(root / "native/target/release" / name, B[name])
    a = {name: ("#!/bin/sh\necho A-" + name + "\n").encode() for name in MEMBERS}
    sleep = pathlib.Path(shutil.which("sleep")).read_bytes()
    if not sleep.startswith(b"\x7fELF"):
        raise AssertionError("live-executable control requires system sleep ELF")
    a["mailbend-core"] = a["mailbend-stdio"] = sleep
    if phase == "fresh":
        (root / "bin").mkdir()
    else:
        meta = root / ".mailbend-install"
        (meta / "states").mkdir(parents=True)
        (meta / "generations").mkdir()
        generations = (("g.AAAAAAAAAAAA", a),)
        if phase == "rollback":
            generations += (("g.BBBBBBBBBBBB", B),)
        for identifier, values in generations:
            directory = meta / "generations" / identifier
            directory.mkdir()
            manifest = "mailbend-generation-v1\ngeneration=" + identifier + "\n"
            for name in MEMBERS:
                write_executable(directory / name, values[name])
                manifest += f"{name} {hashlib.sha256(values[name]).hexdigest()} 0755\n"
            (directory / "MANIFEST").write_text(manifest)
        state = meta / "states/s.AAAAAAAAAAAA"
        state.mkdir()
        active = "g.BBBBBBBBBBBB" if phase == "rollback" else "g.AAAAAAAAAAAA"
        previous = "g.AAAAAAAAAAAA" if phase == "rollback" else "none"
        (state / "FORMAT").write_text("mailbend-install-state-v1\nkind=install\n"
                                      f"active={active}\nprevious={previous}\n")
        (state / "active").symlink_to("../../generations/" + active)
        if previous != "none":
            (state / "previous").symlink_to("../../generations/" + previous)
        (meta / "current").symlink_to("states/s.AAAAAAAAAAAA")
        (root / "bin").symlink_to(".mailbend-install/current/active")
        (root / "bin.prev").symlink_to(".mailbend-install/current/previous")
    env = {"PATH": str(tools), "HOME": str(root), "LANG": "C", "FAULT_ROOT": str(root),
           "FAULT_COMMANDS": json.dumps({name: shutil.which(name) for name in COMMANDS})}
    return a, env


def capture(root):
    """Read current once. Never compare five unrelated opens through bin."""
    current = root / ".mailbend-install/current"
    if not current.is_symlink():
        meta = root / ".mailbend-install"
        if current.exists() or list((meta / "generations").glob("g.*")) or list((meta / "states").glob("s.*")):
            raise AssertionError("missing or invalid current with finalized artifacts")
        return None
    text = os.readlink(current)
    if not text.startswith("states/") or "/" in text.removeprefix("states/"):
        raise AssertionError("invalid selector")
    state = root / ".mailbend-install" / text
    lines = (state / "FORMAT").read_text().splitlines()
    if lines == ["mailbend-install-state-v1", "kind=bootstrap", "active=none", "previous=none"]:
        return None
    if len(lines) != 4 or lines[0] != "mailbend-install-state-v1":
        raise AssertionError("damaged state")
    fields = dict(line.split("=", 1) for line in lines[1:])
    if set(fields) != {"kind", "active", "previous"} or fields["kind"] not in ("install", "rollback"):
        raise AssertionError("damaged state fields")
    for name, role in (("bin", "active"), ("bin.prev", "previous")):
        if os.readlink(root / name) != ".mailbend-install/current/" + role:
            raise AssertionError("damaged root alias")
    sets = []
    for role in ("active", "previous"):
        identifier = fields[role]
        if identifier == "none":
            sets.append(None)
            continue
        if os.readlink(state / role) != "../../generations/" + identifier:
            raise AssertionError("wrong state pairing")
        directory = root / ".mailbend-install/generations" / identifier
        if {path.name for path in directory.iterdir()} != {*MEMBERS, "MANIFEST"}:
            raise AssertionError("damaged generation inventory")
        values = {name: (directory / name).read_bytes() for name in MEMBERS}
        expected = "mailbend-generation-v1\ngeneration=" + identifier + "\n"
        for name in MEMBERS:
            expected += f"{name} {hashlib.sha256(values[name]).hexdigest()} 0755\n"
            if (directory / name).stat().st_mode & 0o7777 != 0o755:
                raise AssertionError("wrong executable mode")
        if (directory / "MANIFEST").read_text() != expected:
            raise AssertionError("damaged manifest")
        sets.append(values)
    return fields["kind"], sets[0], sets[1]


def classify(snapshot, phase, a):
    permitted = {
        "fresh": [None, ("install", B, None)],
        "upgrade": [("install", a, None), ("install", B, a)],
        "rollback": [("install", B, a), ("rollback", a, None)],
    }[phase]
    if snapshot not in permitted:
        raise AssertionError("not an entire allowed active/previous pair")


def terminal(phase, a):
    return {"fresh": ("install", B, None), "upgrade": ("install", B, a),
            "rollback": ("rollback", a, None)}[phase]


def require_result(snapshot, status, phase, a, event=None, how=None, activation=None, stderr=b""):
    if event is None:
        if status != 0 or snapshot != terminal(phase, a):
            raise AssertionError("unfaulted baseline did not complete its exact transition")
        return
    command, args, index = event["command"], event["args"], event["index"]
    retried = how == "before" and (
        (command == "bend" and args[:2] == ["main.bend", "-o"])
        or (command == "ln" and ".current-new." in args[-1]))
    if retried:
        if status != 0 or snapshot != terminal(phase, a):
            raise AssertionError("the specified bounded retry did not finish its transition")
        return
    committed = index > activation or (index == activation and how == "kill-after")
    expected = terminal(phase, a) if committed else {
        "fresh": None, "upgrade": ("install", a, None), "rollback": ("install", B, a)}[phase]
    if status == 0 or snapshot != expected:
        raise AssertionError("required precommit failure was ignored or changed the selected pair"
                             if not committed else "postcommit failure lost the committed complete pair")
    if committed and command == "sync" and b"durability is uncertain" not in stderr:
        raise AssertionError("postcommit flush failure did not disclose uncertain durability")


def oracle_controls():
    a = {name: ("independent-A-" + name).encode() for name in MEMBERS}
    mixed = dict(a, **{"mailbend-tls": B["mailbend-tls"]})
    for wrong in (("install", mixed, None), ("install", B, B),
                  ("install", {k: v for k, v in B.items() if k != "mailbend-core"}, a),
                  ("install", dict(B, **{"mailbend-core": b"truncated"}), a)):
        try:
            classify(wrong, "upgrade", a)
        except AssertionError:
            continue
        raise AssertionError("whole-pair oracle accepted its negative control")
    for snapshot, status, event, activation in (
            (None, 0, None, None),
            (("install", B, None), 0, {"index": 3, "command": "sync", "args": ["--", "FORMAT"]}, 5),
            (("install", B, None), 1, {"index": 3, "command": "sync", "args": ["--", "FORMAT"]}, 5)):
        try:
            require_result(snapshot, status, "fresh", a, event, "before", activation)
        except AssertionError:
            continue
        raise AssertionError("oracle accepted early success or ignored precommit flush failure")
    with tempfile.TemporaryDirectory(prefix="mailbend-oracle-") as directory:
        root = pathlib.Path(directory)
        fixture(root, "upgrade")
        manifest = root / ".mailbend-install/generations/g.AAAAAAAAAAAA/MANIFEST"
        manifest.write_bytes(manifest.read_bytes() + b"unexpected\n")
        try:
            capture(root)
        except AssertionError as error:
            if "damaged manifest" not in str(error):
                raise
        else:
            raise AssertionError("oracle accepted damaged manifest")


def invoke(root, env, phase, index, how):
    (root / "count").write_text("0")
    (root / "events").write_text("")
    command = ["/bin/sh", str(root / "scripts/install.sh")]
    if phase == "rollback":
        command.append("--rollback")
    proc = subprocess.Popen(command, env={**env, "FAULT_AT": str(index), "FAULT_HOW": how},
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        remaining = 15 if DEADLINE is None else min(15, DEADLINE - time.monotonic())
        if remaining <= 0:
            raise AssertionError("fault campaign exhausted its deadline")
        stdout, stderr = proc.communicate(timeout=remaining)
    except BaseException:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate(timeout=5)
        raise
    events = [json.loads(line) for line in (root / "events").read_text().splitlines()]
    if len(events) > 192:
        raise AssertionError("fault trace exceeded its fixed 192-event resource cap")
    return proc.returncode, stdout, stderr, events


def case(phase, index=0, how="before", event=None, activation=None):
    with tempfile.TemporaryDirectory(prefix="mailbend-swap-") as directory:
        root = pathlib.Path(directory)
        a, env = fixture(root, phase)
        held = []
        if phase != "fresh":
            for name in ("mailbend-core", "mailbend-stdio"):
                held.append(subprocess.Popen(
                    [str(root / ".mailbend-install/generations/g.AAAAAAAAAAAA" / name), "120"]))
        try:
            status, stdout, stderr, events = invoke(root, env, phase, index, how)
            snapshot = capture(root)
            classify(snapshot, phase, a)
            try:
                require_result(snapshot, status, phase, a, event, how, activation, stderr)
            except AssertionError as error:
                raise AssertionError(f"{phase} {index}/{how}: {error}; exit={status}; "
                                     f"stdout={stdout!r}; stderr={stderr!r}") from error
            if index and not any(item["index"] == index for item in events):
                raise AssertionError("fault boundary was not reached")
            if any(proc.poll() is not None for proc in held):
                raise AssertionError("running original executable died")
            if index:
                # Every fault case gets a real public retry. A bootstrap selector
                # must not infer that an orphan is the intended next install.
                meta = root / ".mailbend-install"
                generations_before = {path.name for path in (meta / "generations").glob("g.*")}
                states_before = {path.name for path in (meta / "states").glob("s.*")}
                active_before = (root / "bin").resolve() if snapshot is not None else None
                retry, out, err, retry_events = invoke(root, env, phase, 0, "before")
                if retry:
                    raise AssertionError(f"{phase} retry failed at {index}/{how}: {out!r} {err!r}")
                final = capture(root)
                if phase == "rollback":
                    if final != ("rollback", a, None):
                        raise AssertionError("rollback retry toggled or lost A")
                elif final != ("install", B, None if snapshot is None else snapshot[1]):
                    raise AssertionError("install retry did not select complete B")
                else:
                    if (root / "bin").resolve().name in generations_before:
                        raise AssertionError("retry reused or selected a completed orphan")
                    if not all((meta / "generations" / name).is_dir() for name in generations_before):
                        raise AssertionError("retry removed a retained generation")
                    if not all((meta / "states" / name).is_dir() for name in states_before):
                        raise AssertionError("retry removed a retained state")
                    if active_before is not None and (root / "bin.prev").resolve() != active_before:
                        raise AssertionError("retry recorded the wrong previous generation ID")
                if phase == "fresh" and snapshot is None:
                    expected = [meta, root, meta / "generations", meta, meta / "states", meta,
                                meta / "states/bootstrap/FORMAT", meta / "states/bootstrap",
                                meta / "states", meta, root]
                    flushed = []
                    for event in retry_events:
                        if event["command"] == "cargo":
                            break
                        if event["command"] == "sync":
                            flushed.append(pathlib.Path(event["args"][-1]))
                    # The state observations above are the safety oracle. This
                    # additional syscall-boundary check verifies retry durability.
                    position = 0
                    for path in flushed:
                        if position < len(expected) and path == expected[position]:
                            position += 1
                    if position != len(expected):
                        raise AssertionError("bootstrap retry omitted a dependency flush before build")
            print(json.dumps({"phase": phase, "event": index, "action": how, "exit": status,
                              "stdout": stdout.decode("utf-8", "replace"),
                              "stderr": stderr.decode("utf-8", "replace"), "accepted": True}))
            return events
        finally:
            for proc in held:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def main():
    global DEADLINE
    os.umask(0o022)
    started = time.monotonic()
    DEADLINE = started + 600
    oracle_controls()
    cases = 0
    for phase in ("fresh", "upgrade", "rollback"):
        events = case(phase)
        commits = [event["index"] for event in events if event["command"] == "mv"
                   and event["args"][-1].endswith("/.mailbend-install/current")]
        if len(commits) != (2 if phase == "fresh" else 1):
            raise AssertionError("unfaulted trace did not contain the required selector commits")
        activation = commits[-1]
        for event in events:
            # Commands are external filesystem boundaries, not private function mocks.
            # Kill immediately after publication and staging chmod boundaries.
            actions = ["before"]
            args = event["args"]
            if event["command"] == "mv" or (event["command"] == "chmod"
                    and args and args[0] == "755" and any(".stage-" in arg for arg in args)):
                actions.append("kill-after")
            if event["command"] == "sync":
                actions.append("after")
            if event["command"] == "cp":
                actions.append("disk-full")
            for action in actions:
                if time.monotonic() - started > 600:
                    raise AssertionError("fault campaign exceeded its fixed 600-second budget")
                cases += 1
                if cases > 256:
                    raise AssertionError("fault campaign exceeded its fixed 256-case cap")
                case(phase, event["index"], action, event, activation)
    print(f"install swap: {cases} bounded failure cases, whole-pair controls, live ELF and retries passed")
    print("Process interruption and syscall-failure evidence only; not power-loss validation.")


if __name__ == "__main__":
    main()
