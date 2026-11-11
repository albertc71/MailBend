"""One-shot, fail-closed observation of the frozen Markdown r3 source.

Private source preparation only until the exact overlay and run are admitted.
This observer never treats the fourteen unfinished laws as proved.
"""

import base64
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import resource
import signal
import stat
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request


REPO = "albertc71/MailBend"
BASE = "26ddeb04902bbf7e611f6b0cf83377cb11c64c5c"
BRANCH = "validation/markdown-core-r3-20261111-1642"
ENTRY = ".github/workflows/markdown-core-observation.yml"
SELF = "tests/validation/markdown-core-observe.py"
GIB = 1073741824
STREAM = 1048576
GOLDEN_SHA = "9a6d1d66739f7329c8aa77ffd1a535da7550a4885ca229b8133e2a7f66003242"
SOURCE = {
    "src/markdown.bend": (22822, "dd882dfe12c340a7e3d345fc5a0b2cac34060e92ebe84e4ae4d71b5a18c53d02"),
    "tests/unit/markdown.bend": (16728, "0a0f8fa52cd6f3c0a1df45ad0d555b79c37123061ccb85e8dc77466b3502347f"),
    "tests/formal/markdown-core-observers.bend": (24716, "37555c8053bf10cfae9246f4b6f575302da77a0ee8251fa0e0eb6cec056e5be4"),
    "docs/MARKDOWN.md": (24387, "e4bb73c395cce94e32ab1044421a7414e43b6545f57161a729120d8b65ff85f2"),
}
DEPENDENCIES = {
    "src/codec.bend": "cc77ce3928d78a47a3a7b56dd7d6c26d914e36ae",
    "scripts/install-bend.sh": "007205e91c9a034d24c7dafadfbbd70e2ffe17e0",
}
BASE_BLOB = "0edba8267dd17b178dd1d726a0ebeef8d1b317a0"
ARCHIVES = {
    "X64": "63039d1a119f716767ac5a7d8fe0717cfacf219c6c253c35192148e0dade722f",
    "ARM64": "09b813073241628f590f2c2fe420299ec25e4dddd6cf3fdc49c9486339989564",
}
CONTROLS = {
    "N1": (
        b'law inline_observer_rejects_script:\n  {observed_valid(html_observe("<script>x</script>")) == False{} : Bool}',
        b'law inline_observer_rejects_script:\n  {observed_valid(html_observe("<script>x</script>")) == True{} : Bool}',
        "70522fb6886e3c415cad225e1ac171ecd3f3c259f7fea8eafdfba1785bbabd04",
        "inline_observer_rejects_script",
    ),
    "N2": (
        b"[Markdown.Anchor{6n, 23n, 11n, 32n}]",
        b"[Markdown.Anchor{6n, 23n, 12n, 32n}]",
        "aa53a5c494704290a7c397ffe6bd544303d4c1c92208297d4cbd182010095e49",
        "inline_observer_accepts_actual_span",
    ),
}
CHECK_TEXT = b"ALL PROOFS CHECK\nUse --verdict for mathematical validity.\n"
INCOMPLETE = (b"SOME PROOFS FAIL\nError: 14 TODOs found.\n"
              b"The code is incomplete, and not a valid proof yet.\n")


class Blocked(Exception):
    pass


class Failure(Exception):
    pass


def require(ok, message, kind=Blocked):
    if not ok:
        raise kind(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git_blob(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def read_regular(path, cap):
    path = Path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_size <= cap, "not a bounded regular file")
        with os.fdopen(fd, "rb", closefd=False) as handle:
            data = handle.read(cap + 1)
        require(len(data) <= cap, "file exceeds cap")
        return data
    finally:
        os.close(fd)


def put(path, data, mode=0o444):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, "wb", closefd=False) as handle:
            handle.write(data)
            handle.flush()
    finally:
        os.close(fd)


def fetch(url, cap):
    request = urllib.request.Request(url, headers={"User-Agent": "MailBend-finite-observation-r1"})
    expected_host = urllib.parse.urlsplit(url).hostname
    with urllib.request.urlopen(request, timeout=10) as response:
        final = urllib.parse.urlsplit(response.url)
        require(final.scheme == "https" and final.hostname == expected_host,
                "unexpected input redirect")
        data = response.read(cap + 1)
        require(len(data) <= cap, "input response exceeds cap")
        return data


def api(route):
    return json.loads(fetch("https://api.github.com/repos/" + REPO + route, STREAM))


def resource_root():
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    root = Path(os.environ["MB_ROOT"])
    name = "mailbend-md-" + os.environ["GITHUB_RUN_ID"] + "-" + os.environ["MB_EXPECTED_ARCH"].lower()
    require(root == temporary / name and not root.is_symlink(), "unexpected private root")
    info = root.stat()
    require(os.getuid() != 0 and stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o700 and info.st_dev == temporary.stat().st_dev,
            "private root identity/ownership mismatch")
    require(str(info.st_dev) == os.environ["MB_ROOT_DEV"]
            and str(info.st_ino) == os.environ["MB_ROOT_INO"], "private root was replaced")
    with os.scandir(root) as entries:
        names = []
        for entry in entries:
            require(len(names) < 2, "private root is not fresh")
            names.append(entry.name)
    require(names == ["bootstrap.py"], "private root is not bootstrap-only")
    return root

def validate_event():
    require(os.environ.get("GITHUB_EVENT_NAME") == "push", "push-only observation")
    require(os.environ.get("GITHUB_RUN_ATTEMPT") == "1", "reruns are forbidden")
    require(os.environ.get("GITHUB_REPOSITORY") == REPO, "unexpected repository")
    require(os.environ.get("GITHUB_REF") == "refs/heads/" + BRANCH, "unexpected branch")
    event = json.loads(read_regular(os.environ["GITHUB_EVENT_PATH"], STREAM))
    head = os.environ.get("GITHUB_SHA", "")
    require(re.fullmatch(r"[0-9a-f]{40}", head), "invalid head identity")
    require(event.get("created") is True and event.get("deleted") is False and
            event.get("forced") is False and event.get("before") == "0" * 40 and
            event.get("after") == head and event.get("ref") == "refs/heads/" + BRANCH,
            "only the initial nonforced branch push is admitted")
    require(event.get("repository", {}).get("private") is False, "public repository required")
    require(event.get("repository", {}).get("full_name") == REPO, "event repository mismatch")
    require(event.get("repository", {}).get("default_branch") == "main", "default branch changed")
    require(os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted", "standard hosted runner required")
    arch = os.environ.get("RUNNER_ARCH")
    require(arch in ARCHIVES, "unsupported architecture")
    require(platform.machine() == {"X64": "x86_64", "ARM64": "aarch64"}[arch],
            "not the native requested architecture")
    require(os.environ.get("MB_EXPECTED_ARCH") == arch, "runner architecture mismatch")
    require(re.fullmatch(r"[0-9]+", os.environ.get("GITHUB_RUN_ID", "")), "invalid run identity")
    return head, arch


def remote_admission(head):
    repository = api("")
    require(repository.get("private") is False and repository.get("visibility") == "public" and
            repository.get("default_branch") == "main", "live public eligibility changed")
    require(api("/commits/main").get("sha") == BASE, "main changed; fresh disposition required")
    commit = api("/commits/" + head)
    require(commit.get("sha") == head and [p.get("sha") for p in commit.get("parents", [])] == [BASE],
            "not one immutable child of baseline")
    files = commit.get("files", [])
    require(len(files) == 6 and {f.get("filename") for f in files} == set(SOURCE) | {SELF, ENTRY}
            and all(f.get("status") == "added" for f in files), "overlay is not exactly six added paths")
    runs = api("/actions/workflows/markdown-core-observation.yml/runs?branch=" +
               urllib.parse.quote(BRANCH, safe="") + "&event=push&per_page=100")
    records = runs.get("workflow_runs", [])
    require(runs.get("total_count") == 1 and len(records) == 1, "not the only observation run for this branch")
    run = records[0]
    require(str(run.get("id")) == os.environ["GITHUB_RUN_ID"] and run.get("run_attempt") == 1 and
            run.get("head_sha") == head and run.get("head_branch") == BRANCH,
            "run admission identity mismatch")
    return {"run_id": run["id"], "run_created_at": run.get("created_at"),
            "run_started_at": run.get("run_started_at"), "run_url": run.get("html_url"),
            "per_job_queue_seconds": None}


def prepare_inputs(root, head):
    original = root / "input"
    expected = {}
    for name, (length, digest) in SOURCE.items():
        data = fetch(f"https://raw.githubusercontent.com/{REPO}/{head}/{name}", length)
        require(len(data) == length and sha(data) == digest, "frozen source mismatch: " + name)
        put(original / name, data)
        expected[name] = digest
    for name, blob in DEPENDENCIES.items():
        data = fetch(f"https://raw.githubusercontent.com/{REPO}/{BASE}/{name}", 131072)
        require(git_blob(data) == blob, "baseline dependency mismatch: " + name)
        put(original / name, data)
        expected[name] = sha(data)
    formal_name = "tests/formal/markdown-core-observers.bend"
    formal = read_regular(original / formal_name, 32768)
    for label, (before, after, digest, _) in CONTROLS.items():
        require(formal.count(before) == 1, "control target is not unique")
        changed = formal.replace(before, after, 1)
        require(sha(changed) == digest, "control transformation identity mismatch")
        for name in SOURCE:
            data = changed if name == formal_name else read_regular(original / name, 131072)
            put(root / label / name, data)
        put(root / label / "src/codec.bend", read_regular(original / "src/codec.bend", 131072))
    unit = read_regular(original / "tests/unit/markdown.bend", 32768)
    golden = b"".join(line[2:] + b"\n" for line in unit.splitlines() if line.startswith(b"#|"))
    require(len(golden) == 3032 and golden.count(b"\n") == 71 and sha(golden) == GOLDEN_SHA,
            "literal golden identity mismatch")
    put(root / "golden.txt", golden)
    for tree in (original, root / "N1", root / "N2"):
        for directory, _, _ in os.walk(tree, topdown=False, followlinks=False):
            os.chmod(directory, 0o555)
    return original, expected, golden


def exact_result(status, out, err, expected_out, expected_err=b""):
    return status == 0 and out == expected_out and err == expected_err


def comparator_controls(golden):
    require(exact_result(0, golden, b"", golden), "comparator rejects its literal witness", Failure)
    cases = [(0, b"!" + golden[1:], b""), (0, golden[:-1], b""),
             (0, golden.split(b"\n", 1)[1], b""), (0, golden + b"extra\n", b""),
             (1, golden, b""), (0, golden, b"unexpected stderr")]
    require(all(not exact_result(code, out, err, golden) for code, out, err in cases),
            "comparator accepted a corruption", Failure)


NEGATIVE_STDERR = {
    "inline_observer_rejects_script": (
        b"SOME PROOFS FAIL\nError:\n- expected : False{}\n- observed : True{}\n"
        b"Location: inline_observer_rejects_script\n"
        b"418 | def inline_observer_rejects_script():\n"
        b"419>|   {==}\n"
        b"    |   ^^^^\n"
        b"420 | \n"
    ),
    "inline_observer_accepts_actual_span": (
        b"SOME PROOFS FAIL\nError:\n- expected : False{}\n- observed : True{}\n"
        b"Location: inline_observer_accepts_actual_span\n"
        b"444 | def inline_observer_accepts_actual_span():\n"
        b"445>|   {==}\n"
        b"    |   ^^^^\n"
        b"446 | \n"
    ),
}


def finite_negative(status, out, err, name):
    expected = NEGATIVE_STDERR.get(name)
    return expected is not None and status == 1 and out == b"" and err == expected


def diagnostic_controls():
    for name, literal in NEGATIVE_STDERR.items():
        require(finite_negative(1, b"", literal, name), "negative classifier rejects literal", Failure)
        corruptions = [
            (0, b"", literal), (-9, b"", literal), (1, b"x", literal),
            (1, b"", literal[:-1]), (1, b"", literal + b"x"),
            (1, b"", literal[:20]), (1, b"", literal + b"\xff"),
            (1, b"", literal.replace(b"False{}", b"True{}", 1)),
            (1, b"", literal.replace(b"True{}", b"False{}", 1)),
            (1, b"", literal.replace(b"False{}", b"{False{} == True{} : Bool}", 1)),
            (1, b"", literal.replace(b"False{}\n- observed : True{}",
                                    b"True{}\n- observed : False{}", 1)),
            (1, b"", INCOMPLETE), (1, b"", b"SOME PROOFS FAIL\nError parsing\n"),
            (1, b"", b"SOME PROOFS FAIL\nError: missing import\n"), (1, b"", b""),
        ]
        require(all(not finite_negative(code, out, err, name) for code, out, err in corruptions),
                "negative classifier accepted malformed/unrelated evidence", Failure)
        for other in NEGATIVE_STDERR:
            if other != name:
                require(not finite_negative(1, b"", literal, other), "negative classifier crossed names", Failure)

def alarm_action(committing, owned_interval):
    return "terminal" if committing else "latch" if owned_interval else "raise"


def observed_task_total(total, count):
    require(type(total) is int and 0 <= total <= 64 and type(count) is int and count > 0,
            "TASK_COUNT_UNAVAILABLE", Failure)
    result = total + count
    require(result <= 64, "TASK_TARGET_EXCEEDED", Failure)
    return result


def task_and_alarm_controls():
    def total(counts):
        value = 0
        for count in counts:
            value = observed_task_total(value, count)
        return value
    # Counts from live, zombie and dying members all use this same helper.
    require(total([1] + [1] * 63) == 64 and total([1] * 64) == 64,
            "task budget boundary positive", Failure)
    for counts in ([1] + [1] * 64, [1] * 65, [0], [-1], [True], [1.5]):
        refused = False
        try:
            total(counts)
        except Failure:
            refused = True
        require(refused, "task budget accepted an excess or unknown count", Failure)
    require(alarm_action(False, False) == "raise" and
            alarm_action(False, True) == "latch" and
            alarm_action(True, False) == "terminal" and
            alarm_action(True, True) == "terminal", "alarm routing data controls", Failure)


class Clock:
    def __init__(self):
        self.started = float(os.environ["MB_STARTED"])
        self.anchor = float(os.environ["MB_CPU_ANCHOR"])
        self.initial_cpu = float(os.environ["MB_INITIAL_CPU"])
        self.cpu_id = int(os.environ["MB_CPU_ID"])
        self.cancelled = False
        self.committing = False
        self.owned_interval = False
        self.alarm_pending = False
        self.phase = None
        now = time.monotonic()
        require(all(math.isfinite(x) for x in (self.started, self.anchor, self.initial_cpu))
                and 0 <= self.started <= self.anchor <= now and self.initial_cpu >= 0,
                "invalid bootstrap accounting anchor")
        require(os.sched_getaffinity(0) == {self.cpu_id}, "bootstrap affinity changed")
        self.end = min(self.started + 1170, self.anchor + 960 - self.initial_cpu)

    def charge(self):
        return self.initial_cpu + time.monotonic() - self.anchor

    def interrupt(self, number, _frame):
        self.cancelled = True
        if self.committing:
            os._exit(128 + number)

    def alarm(self, _number, _frame):
        action = alarm_action(self.committing, self.owned_interval)
        if action == "terminal":
            os._exit(1)
        if action == "latch":
            self.alarm_pending = True
            return
        raise Failure("PHASE_LIMIT")

    def check(self, deadline=None, cleanup=False):
        now = time.monotonic()
        if self.cancelled and not cleanup:
            raise Failure("CANCELLED")
        if self.alarm_pending and not cleanup:
            raise Failure("PHASE_LIMIT")
        if now >= self.end or (deadline is not None and now >= deadline):
            raise Failure("PHASE_LIMIT")

    def arm(self, deadline):
        signal.setitimer(signal.ITIMER_REAL, max(0.001, deadline - time.monotonic()))


class Phase:
    def __init__(self, supervisor, name, wall, charge=None, setup=False):
        self.supervisor = supervisor
        self.clock = supervisor.clock
        self.name = name
        self.began = self.clock.started if setup else time.monotonic()
        charge_end = (self.clock.anchor + 180 - self.clock.initial_cpu if setup
                      else self.began + charge if charge is not None else self.clock.end)
        self.end = min(self.began + wall, charge_end, self.clock.end)
        self.record = {"stage": name, "began": self.began, "deadline": self.end,
                       "wall_cap": wall, "charge_cap": charge,
                       "status": "UNFINISHED"}

    def __enter__(self):
        self.clock.check(self.end)
        self.clock.phase = self
        self.supervisor.records.append(self.record)
        self.clock.arm(self.end)
        return self

    def __exit__(self, kind, error, _trace):
        try:
            signal.setitimer(signal.ITIMER_REAL, 0)
            self.record["postprocessing_snapshot_seconds"] = time.monotonic() - self.began
            self.record["charge_snapshot"] = self.clock.charge()
            self.record["status"] = "FAILED" if kind else "CHECKED_PENDING_BOUNDARY"
            if kind is None:
                self.clock.check(self.end)
                self.record["status"] = "FINISHED"
        except BaseException:
            self.record["status"] = "FAILED"
            raise
        finally:
            self.clock.phase = None
            self.clock.alarm_pending = False
        return False


def proc_stat(pid):
    data = read_regular(Path("/proc") / str(pid) / "stat", 8192)
    right = data.rfind(b")")
    require(right >= 0, "malformed process metadata", Failure)
    fields = data[right + 2:].split()
    require(len(fields) >= 22, "short process metadata", Failure)
    return {"pid": pid, "state": fields[0].decode("ascii"), "ppid": int(fields[1]),
            "pgid": int(fields[2]), "sid": int(fields[3]), "threads": int(fields[17]),
            "start": int(fields[19]), "rss": max(0, int(fields[21])) * os.sysconf("SC_PAGE_SIZE")}


def task_masks(pid, clock, deadline, cleanup=False):
    count = 0
    directory = Path("/proc") / str(pid) / "task"
    with os.scandir(directory) as entries:
        for entry in entries:
            clock.check(deadline, cleanup=cleanup)
            require(entry.name.isdecimal(), "unexpected task entry", Failure)
            count += 1
            require(count <= 64, "TASK_TARGET_EXCEEDED", Failure)
            try:
                mask = os.sched_getaffinity(int(entry.name))
            except ProcessLookupError:
                continue
            require(mask == {clock.cpu_id}, "AFFINITY_CHANGED", Failure)
    return count


def group_census(clock, deadline, pid=None, known=None, cleanup=False):
    began = time.monotonic()
    known = {} if known is None else known
    own = proc_stat(os.getpid())
    require(task_masks(os.getpid(), clock, deadline, cleanup) == 1,
            "supervisor unexpectedly multithreaded", Failure)
    group_rss = tasks = live = scanned = 0
    found = set()
    if pid is not None:
        with os.scandir("/proc") as entries:
            for entry in entries:
                clock.check(deadline, cleanup=cleanup)
                if not entry.name.isdecimal():
                    continue
                scanned += 1
                require(scanned <= 8192, "process census entry bound", Failure)
                number = int(entry.name)
                try:
                    item = proc_stat(number)
                except (FileNotFoundError, ProcessLookupError):
                    continue
                identity = (number, item["start"])
                previously_owned = identity in known
                if previously_owned and (item["sid"] != pid or item["pgid"] != pid):
                    raise Failure("OWNED_IDENTITY_ESCAPED")
                if item["sid"] != pid and item["pgid"] != pid:
                    continue
                require(item["sid"] == pid and item["pgid"] == pid,
                        "OWNED_GROUP_CHANGED", Failure)
                known[identity] = True
                require(len(known) <= 4096, "owned identity history bound", Failure)
                found.add(identity)
                # Every observed member contributes tasks, including retained zombies.
                tasks = observed_task_total(tasks, item["threads"])
                if item["state"] in ("Z", "X"):
                    continue
                live += 1
                group_rss += item["rss"]
                try:
                    observed_tasks = task_masks(number, clock, deadline, cleanup)
                except (FileNotFoundError, ProcessLookupError):
                    try:
                        again = proc_stat(number)
                    except (FileNotFoundError, ProcessLookupError):
                        continue
                    require(again["start"] != item["start"] or again["state"] in ("Z", "X"),
                            "live owned task census unavailable", Failure)
                    continue
                require(observed_tasks == item["threads"], "owned task census changed during sweep", Failure)
        require(any(identity[0] == pid for identity in found),
                "unreaped leader identity missing", Failure)
    result = {"started": began, "ended": time.monotonic(), "group_rss_estimate": group_rss,
              "supervisor_rss": own["rss"], "same_sweep_sum_estimate": group_rss + own["rss"],
              "group_tasks_observed": tasks, "live_members": live, "process_entries": scanned,
              "atomic_snapshot": False, "hard_quota": False}
    require(group_rss <= GIB, "MEMORY_TARGET_EXCEEDED", Failure)
    return result


def disk_census(root, clock, deadline, identity, remove=False, cleanup=False):
    began = time.monotonic()
    nodes = logical = allocated = 0
    seen = set()
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    root_fd = os.open(root, flags)
    try:
        actual = os.fstat(root_fd)
        require((actual.st_dev, actual.st_ino) == identity and actual.st_uid == os.getuid(),
                "owned work root changed", Failure)
        nodes = 1
        logical = actual.st_size
        allocated = actual.st_blocks * 512
        seen.add(identity)

        def walk(directory, depth):
            nonlocal nodes, logical, allocated
            clock.check(deadline, cleanup=cleanup)
            require(depth <= 64, "directory census depth bound", Failure)
            if remove:
                os.fchmod(directory, 0o700)
            with os.scandir(directory) as entries:
                for entry in entries:
                    clock.check(deadline, cleanup=cleanup)
                    nodes += 1
                    require(nodes <= 16384 and len(entry.name.encode()) <= 4096,
                            "directory census entry bound", Failure)
                    info = os.stat(entry.name, dir_fd=directory, follow_symlinks=False)
                    require(info.st_dev == identity[0] and info.st_uid == os.getuid(),
                            "foreign object in private work directory", Failure)
                    key = (info.st_dev, info.st_ino)
                    if key not in seen:
                        seen.add(key)
                        logical += info.st_size
                        allocated += info.st_blocks * 512
                    require(remove or (logical <= GIB and allocated <= GIB),
                            "DISK_TARGET_EXCEEDED", Failure)
                    if stat.S_ISDIR(info.st_mode):
                        child = os.open(entry.name, flags, dir_fd=directory)
                        try:
                            child_info = os.fstat(child)
                            require((child_info.st_dev, child_info.st_ino) == key,
                                    "directory identity changed", Failure)
                            walk(child, depth + 1)
                            require((os.stat(entry.name, dir_fd=directory, follow_symlinks=False).st_ino
                                     == child_info.st_ino), "directory changed during traversal", Failure)
                        finally:
                            os.close(child)
                        if remove:
                            os.rmdir(entry.name, dir_fd=directory)
                    else:
                        require(stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode),
                                "unexpected private object type", Failure)
                        if remove:
                            os.unlink(entry.name, dir_fd=directory)
        walk(root_fd, 0)
        require((root.lstat().st_dev, root.lstat().st_ino) == identity,
                "private root replaced during traversal", Failure)
    finally:
        os.close(root_fd)
    if remove:
        root.rmdir()
    result = {"started": began, "ended": time.monotonic(), "nodes": nodes,
              "logical_bytes_estimate": logical, "allocated_bytes_estimate": allocated,
              "hard_quota": False, "atomic_snapshot": False, "removed": remove}
    clock.check(deadline, cleanup=cleanup)
    return result

class Supervisor:
    def __init__(self, root, clock):
        self.root = root
        self.clock = clock
        info = root.lstat()
        self.root_identity = (info.st_dev, info.st_ino)
        self.records = []
        self.ownership_uncertain = False

    def phase(self, name, wall, charge=None, setup=False):
        require(not self.ownership_uncertain, "earlier cleanup incomplete", Failure)
        return Phase(self, name, wall, charge, setup)

    def quiet_resources(self, phase):
        phase.record["quiescent_process_observation"] = group_census(self.clock, phase.end)
        phase.record["quiescent_disk_observation"] = disk_census(
            self.root, self.clock, phase.end, self.root_identity)

    def stage(self, phase, env, cwd, argv=None, worker=None):
        clock = self.clock
        clock.check(phase.end)
        require(phase is clock.phase and (argv is None) != (worker is None),
                "stage is not inside its absolute phase", Failure)
        payload_end = phase.end - 4
        cleanup_end = phase.end - 0.5
        require(time.monotonic() < payload_end, "no phase allowance before acquisition", Failure)
        pipes = [None, None]
        pending_pair = None
        all_closed = True
        reads = {}
        buffers = [bytearray(), bytearray()]
        pid = None
        ready = False
        released = False
        status = usage = None
        reason = None
        overflow = False
        cleanup_ok = False
        known = {}
        previous_mask = None
        observed = {"samples": 0, "group_rss_max_estimate": 0, "group_tasks_max_observed": 0,
                    "max_process_sampling_gap": 0, "max_disk_sampling_gap": 0,
                    "memory_disk_tasks_are_hard_limits": False}
        last_process = last_disk = None

        def close_write(index):
            nonlocal all_closed
            pair = pipes[index]
            if pair is None or pair[1] is None:
                return
            try:
                os.close(pair[1])
            except BaseException:
                all_closed = False
                raise
            finally:
                pipes[index] = (pair[0], None)

        def close_read(fd):
            nonlocal all_closed
            try:
                os.close(fd)
            except BaseException:
                all_closed = False
                raise
            finally:
                reads.pop(fd, None)
                for index, pair in enumerate(pipes):
                    if pair is not None and pair[0] == fd:
                        pipes[index] = (None, pair[1])

        def drain():
            nonlocal overflow
            for fd, index in tuple(reads.items()):
                try:
                    data = os.read(fd, 65536)
                except BlockingIOError:
                    continue
                if not data:
                    close_read(fd)
                    continue
                allowed = max(0, STREAM - len(buffers[index]))
                buffers[index].extend(data[:allowed])
                overflow |= len(data) > allowed

        def observe(deadline, cleaning=False):
            nonlocal last_process
            sample = group_census(clock, deadline, pid, known, cleanup=cleaning)
            if last_process is not None:
                observed["max_process_sampling_gap"] = max(
                    observed["max_process_sampling_gap"], sample["started"] - last_process)
            last_process = sample["started"]
            observed["samples"] += 1
            observed["group_rss_max_estimate"] = max(observed["group_rss_max_estimate"],
                                                   sample["group_rss_estimate"])
            observed["group_tasks_max_observed"] = max(observed["group_tasks_max_observed"],
                                                       sample["group_tasks_observed"])
            observed["last_process_sweep"] = sample
            return sample

        def observe_disk(deadline):
            nonlocal last_disk
            sample = disk_census(self.root, clock, deadline, self.root_identity)
            if last_disk is not None:
                observed["max_disk_sampling_gap"] = max(
                    observed["max_disk_sampling_gap"], sample["started"] - last_disk)
            last_disk = sample["started"]
            observed["last_disk_sweep"] = sample

        self.ownership_uncertain = True
        clock.owned_interval = True
        try:
            for index in range(2):
                clock.check(payload_end)
                pending_pair = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
                pipes[index] = pending_pair
                pair = pending_pair
                pending_pair = None
                reads[pair[0]] = index
            clock.check(payload_end)
            previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK,
                                                    {signal.SIGALRM, signal.SIGINT, signal.SIGTERM})
            pid = os.fork()
            if pid == 0:
                try:
                    for index, (read_fd, write_fd) in enumerate(pipes):
                        os.close(read_fd)
                        os.set_blocking(write_fd, True)
                        os.dup2(write_fd, index + 1)
                        os.close(write_fd)
                    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGALRM, signal.SIGCHLD):
                        signal.signal(number, signal.SIG_DFL)
                    signal.setitimer(signal.ITIMER_REAL, 0)
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                    null = os.open("/dev/null", os.O_RDONLY)
                    os.dup2(null, 0)
                    os.close(null)
                    os.setsid()
                    os.kill(os.getpid(), signal.SIGSTOP)
                    require(os.sched_getaffinity(0) == {clock.cpu_id}, "child affinity mismatch", Failure)
                    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
                    resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))
                    resource.setrlimit(resource.RLIMIT_FSIZE, (GIB, GIB))
                    os.chdir(cwd)
                    if worker is not None:
                        os.environ.clear()
                        os.environ.update(env)
                        worker()
                        os._exit(0)
                    os.execve(argv[0], argv, env)
                except BaseException as error:
                    try:
                        os.write(2, ("owned-stage error: " + str(error) + "\n").encode()[:8192])
                    except BaseException:
                        pass
                    os._exit(125)
            # Signals remain blocked until the returned child PID is owned.
            restore_mask = previous_mask
            previous_mask = None
            signal.pthread_sigmask(signal.SIG_SETMASK, restore_mask)
            # Ownership is already inside this try/finally at fork return.
            for index in range(2):
                close_write(index)
            readiness_end = min(time.monotonic() + 2, payload_end)
            while time.monotonic() < readiness_end:
                clock.check(payload_end)
                event = os.waitid(os.P_PID, pid, os.WSTOPPED | os.WEXITED | os.WNOHANG | os.WNOWAIT)
                if event is not None:
                    if event.si_code == os.CLD_STOPPED and event.si_status == signal.SIGSTOP:
                        identity = proc_stat(pid)
                        require(identity["sid"] == pid and identity["pgid"] == pid,
                                "owned session readiness mismatch", Failure)
                        known[(pid, identity["start"])] = True
                        ready = True
                        observe(payload_end)
                        observe_disk(payload_end)
                        os.kill(pid, signal.SIGCONT)
                        released = True
                    break
                time.sleep(0.01)
            require(released, "READINESS_FAILED", Failure)
            while True:
                clock.check(payload_end)
                drain()
                require(not overflow, "STREAM_LIMIT", Failure)
                observe(payload_end)
                if last_disk is None or time.monotonic() - last_disk >= 0.5:
                    observe_disk(payload_end)
                event = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                if event is not None:
                    break
                time.sleep(min(0.05, max(0, payload_end - time.monotonic())))
        except BaseException as error:
            reason = type(error).__name__ + ": " + str(error)[:512]
        finally:
            try:
                # Alarms only latch throughout this acquired-resource interval.
                try:
                    signal.setitimer(signal.ITIMER_REAL, 0)
                except BaseException as error:
                    reason = reason or "TIMER_DISARM_FAILED: " + type(error).__name__
                if previous_mask is not None:
                    try:
                        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                    except BaseException as error:
                        reason = reason or "SIGNAL_RESTORE_FAILED: " + type(error).__name__
                if pending_pair is not None and pending_pair not in pipes:
                    for fd in pending_pair:
                        try:
                            os.close(fd)
                        except BaseException:
                            all_closed = False
                            reason = reason or "PENDING_DESCRIPTOR_CLOSE_FAILED"
                pending_pair = None
                for index in range(2):
                    try:
                        close_write(index)
                    except BaseException:
                        reason = reason or "PARENT_DESCRIPTOR_CLOSE_FAILED"
                if pid is not None and pid > 0:
                    try:
                        if ready:
                            try:
                                os.killpg(pid, signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                            grace = min(time.monotonic() + 1, cleanup_end - 1)
                            while time.monotonic() < grace:
                                drain()
                                if observe(grace, cleaning=True)["live_members"] == 0:
                                    break
                                time.sleep(0.01)
                    except BaseException as error:
                        reason = reason or "CLEANUP_OBSERVATION: " + type(error).__name__
                    finally:
                        # This is the last PID/PGID signal. Leader ownership is retained.
                        try:
                            if ready:
                                os.killpg(pid, signal.SIGKILL)
                            else:
                                os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        except BaseException as error:
                            reason = reason or "OWNED_KILL_FAILED: " + type(error).__name__
                    group_empty = not ready
                    try:
                        while time.monotonic() < cleanup_end:
                            drain()
                            if ready and not group_empty:
                                group_empty = observe(cleanup_end, cleaning=True)["live_members"] == 0
                            # Reap only after the final group signal. No blocking wait.
                            if status is None and group_empty:
                                got, value, child_usage = os.wait4(pid, os.WNOHANG)
                                if got == pid:
                                    status = os.waitstatus_to_exitcode(value)
                                    usage = child_usage
                            if status is not None and group_empty and not reads:
                                cleanup_ok = True
                                break
                            time.sleep(0.01)
                    except BaseException as error:
                        reason = reason or "CLEANUP_OBSERVATION: " + type(error).__name__
                    # If census failed, still make one bounded reap attempt after the last signal.
                    if status is None:
                        try:
                            got, value, child_usage = os.wait4(pid, os.WNOHANG)
                            if got == pid:
                                status = os.waitstatus_to_exitcode(value)
                                usage = child_usage
                        except (ChildProcessError, OSError):
                            pass
                    if not cleanup_ok:
                        self.ownership_uncertain = True
                        reason = reason or "CLEANUP_FAILED"
                else:
                    cleanup_ok = True
                try:
                    drain()
                except BaseException as error:
                    reason = reason or "FINAL_DRAIN_FAILED: " + type(error).__name__
                if overflow:
                    reason = "STREAM_LIMIT"
                for pair in tuple(pipes):
                    if pair is not None and pair[0] is not None:
                        try:
                            close_read(pair[0])
                        except BaseException:
                            reason = reason or "PARENT_DESCRIPTOR_CLOSE_FAILED"
                endpoints_closed = all(pair is None or pair == (None, None) for pair in pipes)
                self.ownership_uncertain = not (cleanup_ok and all_closed and endpoints_closed)
                phase.record.update({"exit": status, "reason": reason,
                                     "cleanup": not self.ownership_uncertain,
                                     "child_cleanup": cleanup_ok,
                                     "descriptor_cleanup": all_closed and endpoints_closed,
                                     "stream_overflow": overflow, "observation": observed,
                                     "wait4_maxrss_kib": usage.ru_maxrss if usage else None,
                                     "waited_child_user_seconds": usage.ru_utime if usage else None,
                                     "waited_child_system_seconds": usage.ru_stime if usage else None})
                for key, data in zip(("stdout", "stderr"), buffers):
                    phase.record[key] = {"size": len(data), "sha256": sha(data),
                                         "base64": base64.b64encode(data).decode("ascii")}
            finally:
                clock.owned_interval = False

        # Accounting includes acquisition, all drains, closing and record encoding.
        clock.arm(phase.end)
        clock.check(phase.end)
        require(reason is None, phase.name + ": " + str(reason), Failure)
        self.quiet_resources(phase)
        result = status, bytes(buffers[0]), bytes(buffers[1])
        clock.check(phase.end)
        return result

def payload_env(root, safe_path, deadline):
    return {"HOME": str(root / "home"), "TMPDIR": str(root / "tmp"),
            "PATH": safe_path, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "BEND_NO_TELEMETRY": "1", "CC": "/usr/bin/clang-18",
            "MB_PHASE_DEADLINE": repr(deadline)}


def worker_check():
    require(time.monotonic() < float(os.environ["MB_PHASE_DEADLINE"]),
            "setup worker deadline", Failure)


def bounded_capture(argv):
    worker_check()
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    data = [bytearray(), bytearray()]
    streams = {}
    try:
        for index, stream in enumerate((process.stdout, process.stderr)):
            os.set_blocking(stream.fileno(), False)
            streams[stream.fileno()] = index
        while True:
            worker_check()
            for fd, index in tuple(streams.items()):
                try:
                    chunk = os.read(fd, 4096)
                except BlockingIOError:
                    continue
                if not chunk:
                    del streams[fd]
                else:
                    require(len(data[index]) + len(chunk) <= 8192,
                            "metadata command stream exceeds 8 KiB")
                    data[index].extend(chunk)
            status = process.poll()
            if status is not None and not streams:
                require(status == 0, "metadata command failed")
                return bytes(data[0]), bytes(data[1])
            time.sleep(0.01)
    finally:
        process.stdout.close()
        process.stderr.close()
        # No blocking cleanup wait. Any surviving child remains in the outer
        # still-owned setup session, whose finite supervisor cleans it.


def run_installer(argv):
    worker_check()
    process = subprocess.Popen(argv)
    while process.poll() is None:
        worker_check()
        time.sleep(0.05)
    require(process.returncode == 0, "official installer failed")


def metadata_and_install(root, original, arch):
    run_installer(["/bin/sh", str(original / "scripts/install-bend.sh")])
    bend = root / "home/.bend/bin/bend"
    version, errors = bounded_capture([str(bend), "version"])
    require(version == b"bend 2.0.35\n" and not errors, "Bend version mismatch")
    base = read_regular(root / "home/.bend/bend2/base.bend", 1048576)
    require(git_blob(base) == BASE_BLOB, "extracted Base mismatch")
    clang = Path("/usr/bin/clang-18").resolve(strict=True)
    info = clang.stat()
    require(info.st_uid == 0 and not info.st_mode & 0o022 and stat.S_ISREG(info.st_mode),
            "clang executable is not a protected regular system file")
    version, errors = bounded_capture([str(clang), "--version"])
    require(not errors and re.search(rb"(?m)^(?:Ubuntu )?clang version 18\.1\.3(?:\s|$)",
                                    version), "clang must be exactly 18.1.3")
    worker_check()
    identities = {"bend": sha(read_regular(bend, 268435456)), "base": sha(base),
                  "clang_path": str(clang), "clang": sha(read_regular(clang, 268435456)),
                  "clang_version": version.decode(), "archive_verified_by_installer": ARCHIVES[arch],
                  "machine": platform.machine(), "kernel": platform.release(),
                  "libc": platform.libc_ver()}
    packages, errors = bounded_capture(["/usr/bin/dpkg-query", "-W", "-f=${Package}=${Version}\n",
                                       "clang-18", "libc6", "binutils"])
    require(not errors, "package identity unavailable")
    identities["packages"] = packages.decode("utf-8", errors="strict")
    for name in ("ld", "as"):
        worker_check()
        target = Path("/usr/bin") / name
        require(target.exists(), "system linker/assembler unavailable")
        identities[name] = {"path": str(target.resolve()),
                            "sha256": sha(read_regular(target.resolve(), 268435456))}
        (root / "path" / name).symlink_to(target.resolve())
    put(root / "toolchain.json", json.dumps(identities, sort_keys=True).encode())
    worker_check()


def immutable_recheck(original, expected, clock, deadline):
    for name, digest in expected.items():
        clock.check(deadline)
        require(sha(read_regular(original / name, 131072)) == digest, "input changed: " + name, Failure)


def emit_report(report, clock, deadline):
    clock.check(deadline)
    data = json.dumps(report, sort_keys=True).encode("utf-8") + b"\n"
    require(len(data) <= 4194304, "report exceeds 4 MiB", Failure)
    os.set_blocking(1, False)
    offset = 0
    while offset < len(data):
        clock.check(deadline)
        try:
            written = os.write(1, data[offset:offset + 65536])
            require(written > 0, "report write made no progress", Failure)
            offset += written
        except BlockingIOError:
            time.sleep(0.01)
    clock.check(deadline)

def decision_controls():
    def eligible(complete, cleaned, emitted, cancelled, within):
        return complete and cleaned and emitted and not cancelled and within
    require(eligible(True, True, True, False, True), "completion model positive", Failure)
    for case in ((False, True, True, False, True), (True, False, True, False, True),
                 (True, True, False, False, True), (True, True, True, True, True),
                 (True, True, True, False, False)):
        require(not eligible(*case), "completion model accepted a failed precondition", Failure)
    # These finite Boolean witnesses do not simulate OS lifecycle or signal timing.


def main():
    clock = Clock()
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    signal.signal(signal.SIGALRM, clock.alarm)
    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, clock.interrupt)
    supervisor = root = original = expected = None
    candidate = False
    payload_started = False
    report = {"schema": 2, "baseline": BASE, "source": SOURCE, "unrun_initial": 71,
              "universal_obligations_open": 14, "proof_pass": False,
              "resource_contract": "sampled-targets-trusted-common-affinity",
              "hard_memory_disk_task_quota": False,
              "cpu_charge_is_measured_cpu": False,
              "common_cpu_id": clock.cpu_id,
              "charge_anchor_monotonic": clock.anchor,
              "bootstrap_self_cpu_charge": clock.initial_cpu,
              "charge_assumption": "all cooperating workload threads retain the common CPU",
              "historical_resource_peak_proved": False}
    try:
        root = resource_root()
        supervisor = Supervisor(root, clock)
        with supervisor.phase("S0/S1", 300, 180, setup=True) as phase:
            head, arch = validate_event()
            expected_self = os.environ.get("MB_HARNESS_SHA", "")
            require(re.fullmatch(r"[0-9a-f]{64}", expected_self) and
                    sha(read_regular(__file__, 131072)) == expected_self, "harness identity mismatch")
            report["admission"] = remote_admission(head)
            original, expected, golden = prepare_inputs(root, head)
            comparator_controls(golden)
            diagnostic_controls()
            decision_controls()
            task_and_alarm_controls()
            report["source_defined_data_controls"] = "PURE_DATA_CONTROLS_CHECKED"
            for name in ("home", "tmp", "path", "out"):
                (root / name).mkdir(mode=0o700)
            for name in ("curl", "tar", "sha256sum", "uname", "mktemp", "mkdir", "rm", "mv",
                         "clang-18", "dpkg-query", "ld", "as"):
                require(Path("/usr/bin", name).exists(), "missing prerequisite: " + name)
            supervisor.quiet_resources(phase)
            result = supervisor.stage(
                phase, payload_env(root, "/usr/bin:/bin", phase.end - 4), root,
                worker=lambda: metadata_and_install(root, original, arch))
            require(result[0] == 0, "official toolchain setup failed")
            metadata = json.loads(read_regular(root / "toolchain.json", 32768))
            report.update({"head": head, "arch": arch, "toolchain": metadata,
                           "harness": expected_self, "image": os.environ.get("ImageVersion")})
            bend = str(root / "home/.bend/bin/bend")
        payload_started = True
        for name, file in (("S2", "src/markdown.bend"), ("S3", "tests/unit/markdown.bend")):
            with supervisor.phase(name, 120, 110) as phase:
                env = payload_env(root, str(root / "path"), phase.end - 4)
                env["CC"] = metadata["clang_path"]
                result = supervisor.stage(phase, env, original, argv=[bend, file, "--check-only"])
                require(exact_result(*result, CHECK_TEXT), name + " did not check exactly", Failure)
                phase.record["semantic_result"] = "EXACT_CHECK_ONLY"
        formal_name = "tests/formal/markdown-core-observers.bend"
        with supervisor.phase("S4", 120, 110) as phase:
            env = payload_env(root, str(root / "path"), phase.end - 4)
            env["CC"] = metadata["clang_path"]
            result = supervisor.stage(phase, env, original, argv=[bend, formal_name, "--check-only"])
            require(result == (1, b"", INCOMPLETE), "not EXPECTED_INCOMPLETE_14", Failure)
            phase.record["semantic_result"] = "EXPECTED_INCOMPLETE_14"
            report["formal"] = "EXPECTED_INCOMPLETE_14"
        for name, label in (("S5a", "N1"), ("S5b", "N2")):
            with supervisor.phase(name, 60, 55) as phase:
                require(sha(read_regular(root / label / formal_name, 32768)) == CONTROLS[label][2],
                        "control copy changed", Failure)
                env = payload_env(root, str(root / "path"), phase.end - 4)
                env["CC"] = metadata["clang_path"]
                result = supervisor.stage(phase, env, root / label,
                                          argv=[bend, formal_name, "--check-only"])
                require(finite_negative(*result, CONTROLS[label][3]),
                        "INCONCLUSIVE_OR_FAILED_CONTROL: " + label, Failure)
                phase.record["semantic_result"] = "EXACT_NAMED_BOOLEAN_REJECTION"
        with supervisor.phase("S6", 300, 280) as phase:
            require(sha(read_regular(Path(metadata["clang_path"]), 268435456)) == metadata["clang"],
                    "clang changed before build", Failure)
            binary = root / "out/markdown-unit"
            env = payload_env(root, str(root / "path"), phase.end - 4)
            env["CC"] = metadata["clang_path"]
            result = supervisor.stage(phase, env, original,
                                      argv=[bend, "tests/unit/markdown.bend", "-o", str(binary)])
            require(exact_result(*result, b""), "native compilation output/exit mismatch", Failure)
            compiled = read_regular(binary, 268435456)
            require(len(compiled) >= 64 and compiled[:6] == b"\x7fELF\x02\x01" and
                    struct.unpack_from("<H", compiled, 18)[0] == {"X64": 62, "ARM64": 183}[arch],
                    "compiled file is not the expected native ELF", Failure)
            report["binary"] = sha(compiled)
            del compiled
            phase.record["semantic_result"] = "EXPECTED_NATIVE_ELF"
        with supervisor.phase("S7", 30, 25) as phase:
            env = payload_env(root, str(root / "path"), phase.end - 4)
            env["CC"] = metadata["clang_path"]
            result = supervisor.stage(phase, env, root, argv=[str(binary)])
            require(exact_result(*result, golden), "unit exit/stderr/literal stdout mismatch", Failure)
            report["unit_assertions_observed"] = 71
            phase.record["semantic_result"] = "EXACT_71_LITERAL_LINES"
        candidate = True
    except BaseException as error:
        report["reason"] = type(error).__name__ + ": " + str(error)[:2048]
    # No COMPLETE latch exists before all cleanup/output/charging is finished.
    final_began = time.monotonic()
    final_end = min(final_began + 30, clock.end)
    try:
        clock.check(final_end)
        clock.arm(final_end)
        if candidate:
            immutable_recheck(original, expected, clock, final_end)
            for label in CONTROLS:
                require(sha(read_regular(root / label / formal_name, 32768)) == CONTROLS[label][2],
                        "control copy changed before finalization", Failure)
        if supervisor is not None:
            report["stages"] = supervisor.records
            if supervisor.ownership_uncertain:
                candidate = False
                report["work_removed"] = False
                report["cleanup_uncertain"] = True
            else:
                report["final_process_observation"] = group_census(clock, final_end)
                report["work_removal"] = disk_census(root, clock, final_end,
                                                    supervisor.root_identity, remove=True)
                report["work_removed"] = True
        report["outcome"] = ("FINITE_RESULTS_OBSERVED_PENDING_FINAL_EXIT" if candidate else
                             "OBSERVATION_FAILED" if payload_started else "SETUP_BLOCKED")
        own = resource.getrusage(resource.RUSAGE_SELF)
        report["supervisor_cpu_snapshot"] = own.ru_utime + own.ru_stime
        report["conservative_charge_snapshot"] = clock.charge()
        report["wall_snapshot_seconds"] = time.monotonic() - clock.started
        report["finalization_deadline"] = final_end
        report["success_requires"] = "zero terminal process/job status AND finite=true"
        emit_report(report, clock, final_end)
        clock.check(final_end)
        if not candidate:
            return 1
        # A signal after this point exits nonzero instead of preserving success.
        clock.committing = True
        output = os.environ.get("GITHUB_OUTPUT")
        require(output is not None, "job output channel missing", Failure)
        fd = os.open(output, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            require(stat.S_ISREG(os.fstat(fd).st_mode), "job output channel is not regular", Failure)
            require(os.write(fd, b"finite=true\n") == 12, "short job output write", Failure)
        finally:
            os.close(fd)
        clock.check(final_end)
        audit = {"finalization_charge_snapshot": clock.charge(),
                 "finalization_wall_snapshot_seconds": time.monotonic() - clock.started,
                 "finalization_snapshot_precedes_this_record": True,
                 "post_emission_acceptance_check_required": True,
                 "universal_obligations_open": 14, "proof_pass": False}
        emit_report(audit, clock, final_end)
        # This check includes both report emissions and the output-channel write.
        clock.check(final_end)
        os._exit(0)
    except BaseException as error:
        try:
            os.set_blocking(2, False)
            os.write(2, ("FINALIZATION_FAILED: " + type(error).__name__ + ": " +
                         str(error)[:1024] + "\n").encode()[:2048])
        except BaseException:
            pass
        return 1


if __name__ == "__main__":
    sys.exit(main())
