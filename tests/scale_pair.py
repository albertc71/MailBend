#!/usr/bin/env python3
"""Verify a fixed-reference, same-runner scale pair without changing measurements."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import math
import shutil
import statistics
import tempfile
import time
import os
import pathlib
import re
import stat
import subprocess
import sys
import types

REFERENCE_SHA = "8ae04b1b3c773d14dea78e167e0047adab1e7cb5"
PINNED = {
    "tests/test-scale.py": "ac5dcef24a0111353573f7b161e8655f013575d56c152d2fc178b6b1ed06b1ef",
    "tests/scale_fixtures.py": "263ada116e581d12a150d4f3f9de57b607dcc2917db3b7ccc177249319159638",
    "tests/scale_support/v1/fake_mail_server.py": "3f5ac5c1bc4167537dc7511a1c98fbd938a05fe6c8184c8104157a7e79264e9c",
    "tests/scale_support/v1/fake_typesafe.py": "883ca82b5048f6ab2fbe20325a2b17801fae1090e9ed936b1671b9c9f48b5083",
    "tests/scale_support/v1/image_fixtures.py": "9a1af6dd57315bbc7f887af6b80cc2043d36bd980a66cf6e9a70750a7f4be2d0",
}
INSTALLERS = ("scripts/install.sh", "scripts/install-bend.sh", "scripts/install-rust.sh",
              "scripts/install-lean.sh")
# Candidate-only source migration reviewed in PR #258 at b00464bda8bb70f9238036301242eb6df5131f99.
# The three helpers are one indivisible tuple; neither mixed revisions nor a
# candidate-provided policy is accepted. Reference setup still uses old bytes.
CANDIDATE_HELPER_TUPLE = (
    "57c7d071b6f0155c69058a883e83b97f6a76a17d438d9cce1d2b870576c2af1b",
    "0396875e0f8c09599c9badbe4fbde259b61138308977835fbf0c8b4c198c7a17",
    "4b30ca5f48136b481243ea0c819c970563e13e96ef660b8bd7ad8c738ce14374",
)
# The hook-only launcher revision in PR #272 at 2920a261a1361e1631631b4f218707a9ffbb52dc.
CANDIDATE_LAUNCHER_SHA256 = "68cf6c6e6c671585d8752b653d8e76728d00306a1cd76b6f7723257d1546ffd8"
# The report usage-comment revision in PR #292 at 947fcc06a8c31bde25fa935d10443f7b1690dd28.
CANDIDATE_REPORT_LAUNCHER_SHA256 = "251f054ca4f223c180602b00c16192f08dc7ff88d77522951efbfd3a021af26e"
# The compiled-install update refusal; exact bytes documented in tests/SCALE.md.
CANDIDATE_INSTALLER_SHA256 = "ae7a0f7ef0c8606488cbd5414c5a3914a027fce6773b9cae2bdf865b9d564f9b"
EXECUTABLES = ("bin/mailbend-core", "bin/mailbend-tls", "bin/mailbend-attach",
               "bin/mailbend-typesafe", "bin/mailbend-stdio", "scripts/mailbend")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], timeout=30)


def regular(root, relative, executable=False):
    path = root / relative
    for part in [path, *path.parents]:
        if part == root.parent:
            break
        require(not part.is_symlink(), f"symlink forbidden: {path}")
    info = path.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
            f"not an unaliased regular file: {path}")
    require(not executable or os.access(path, os.X_OK), f"not executable: {path}")
    return path, info


# Candidate-only managed v1 installer, launcher and sourced validator. These
# literals require independent review of the exact three files as one unit.
MANAGED_SCRIPT_PATHS = ("scripts/install.sh", "scripts/mailbend", "scripts/install-layout.sh")
MANAGED_SCRIPT_TUPLE = (
    "1e6021a670a6d26f2a68a27cd748c1b63238e816dd1dbcf677ba6e9d3b934326",
    "90d6cbca18d2ed0e24883a7417225b98657dd023fee8afe4686ba9c9fecb6aac",
    "3bd34c8bbe5d8d5d10359a378b9d7df154e63946a3117125f718696f7489b406",
)
GENERATION_MEMBERS = ("mailbend-core", "mailbend-tls", "mailbend-attach",
                      "mailbend-typesafe", "mailbend-stdio")


def script_layout(reference, candidate):
    actual = tuple(sha(regular(candidate, name)[0].read_bytes())
                   for name in MANAGED_SCRIPT_PATHS[:2])
    original = tuple(sha(git(reference, "show", f"{REFERENCE_SHA}:{name}"))
                     for name in MANAGED_SCRIPT_PATHS[:2])
    for name, expected in zip(MANAGED_SCRIPT_PATHS[:2], original):
        require(sha(regular(reference, name)[0].read_bytes()) == expected,
                "fixed launcher/installer changed")
    if actual == MANAGED_SCRIPT_TUPLE[:2]:
        path, _ = regular(candidate, MANAGED_SCRIPT_PATHS[2])
        require(sha(path.read_bytes()) == MANAGED_SCRIPT_TUPLE[2],
                "candidate managed validator is not a reviewed revision")
        return "managed-v1"
    require(actual[0] in (original[0], CANDIDATE_INSTALLER_SHA256),
            "candidate installer is not a reviewed revision")
    require(actual[1] in (original[1], CANDIDATE_LAUNCHER_SHA256,
                          CANDIDATE_REPORT_LAUNCHER_SHA256),
            "candidate launcher is not a reviewed revision")
    require(actual[0] != MANAGED_SCRIPT_TUPLE[0] and actual[1] != MANAGED_SCRIPT_TUPLE[1],
            "mixed managed/legacy script pair")
    return "flat"


def metadata(info):
    return {"device": info.st_dev, "inode": info.st_ino, "size": info.st_size,
            "mode": info.st_mode, "uid": info.st_uid, "links": info.st_nlink,
            "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns}


def opened_file(path, info, limit=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        require(metadata(before) == metadata(info), f"file changed before open: {path}")
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
                f"not an unaliased regular file: {path}")
        digest, data = hashlib.sha256(), bytearray()
        while True:
            chunk = os.read(fd, 1024 * 1024 if limit is None else limit + 1 - len(data))
            if not chunk:
                break
            digest.update(chunk)
            if limit is not None:
                data.extend(chunk)
                require(len(data) <= limit, f"oversized record: {path}")
        require(metadata(os.fstat(fd)) == metadata(before)
                == metadata(path.lstat()), f"file changed during hashing: {path}")
        return {**metadata(before), "sha256": digest.hexdigest()}, bytes(data)
    finally:
        os.close(fd)


def trusted_root(root):
    owner = root.lstat().st_uid
    child = None
    for path in (root, *root.parents):
        info = path.lstat()
        require(stat.S_ISDIR(info.st_mode), f"linked checkout ancestor: {path}")
        require(info.st_uid in (0, owner), f"foreign checkout ancestor: {path}")
        if info.st_mode & 0o022:
            require(path != root and info.st_uid == 0 and info.st_mode & stat.S_ISVTX
                    and child is not None and child.st_uid in (0, owner)
                    and not child.st_mode & 0o022, f"writable checkout ancestor: {path}")
        if path == root:
            require(not info.st_mode & 0o7000, "special checkout permissions")
        child = info
    return owner


@contextlib.contextmanager
def locked_roots(roots):
    with contextlib.ExitStack() as stack:
        saved = {}
        for root in sorted(roots):
            trusted_root(root)
            fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            stack.callback(os.close, fd)
            try:
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise ValueError(f"checkout install lock is busy: {root}") from exc
            saved[root] = (os.fstat(fd).st_dev, os.fstat(fd).st_ino)
            bin_dir = root / "bin"
            if bin_dir.is_dir() and not bin_dir.is_symlink():
                legacy = os.open(bin_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                stack.callback(os.close, legacy)
                try:
                    fcntl.flock(legacy, fcntl.LOCK_SH | fcntl.LOCK_NB)
                except BlockingIOError as exc:
                    raise ValueError(f"legacy bin install lock is busy: {root}") from exc
                require((os.fstat(legacy).st_dev, os.fstat(legacy).st_ino)
                        == (bin_dir.lstat().st_dev, bin_dir.lstat().st_ino),
                        "legacy bin changed during lock acquisition")
        def same_roots():
            for root, identity in saved.items():
                info = root.lstat()
                require(stat.S_ISDIR(info.st_mode) and (info.st_dev, info.st_ino) == identity,
                        "checkout root moved or was replaced")
        same_roots()
        yield
        same_roots()


def managed_snapshot(root, seen):
    owner = trusted_root(root)
    device = root.lstat().st_dev
    nodes, records, files = {}, {}, {}

    def node(path, kind, mode=None, target=None):
        info = path.lstat()
        require(info.st_uid == owner and info.st_dev == device,
                f"managed owner or filesystem: {path}")
        require(stat.S_IFMT(info.st_mode) == kind, f"managed object type: {path}")
        if mode is not None:
            require(stat.S_IMODE(info.st_mode) == mode, f"managed object mode: {path}")
        value = metadata(info)
        if kind == stat.S_IFLNK:
            text = os.readlink(path)
            require(text == target, f"managed link target: {path}")
            value["target"] = text
        nodes[str(path.relative_to(root))] = value
        return info

    def directory(path):
        return node(path, stat.S_IFDIR, 0o755)

    def record(path, limit):
        info = node(path, stat.S_IFREG, 0o644)
        require(0 < info.st_size <= limit, f"oversized or empty record: {path}")
        identity, data = opened_file(path, info, limit)
        try:
            text = data.decode("ascii")
        except UnicodeDecodeError as exc:
            raise ValueError(f"non-ASCII record: {path}") from exc
        records[str(path.relative_to(root))] = {**identity, "bytes": text}
        return data

    meta = root / ".mailbend-install"
    for path in (meta, meta / "generations", meta / "states"):
        directory(path)
    node(root / "bin", stat.S_IFLNK, target=".mailbend-install/current/active")
    node(root / "bin.prev", stat.S_IFLNK, target=".mailbend-install/current/previous")
    current = meta / "current"
    selected = os.readlink(current)
    require(re.fullmatch(r"states/s\.[A-Za-z0-9]{12}", selected) is not None,
            "managed current must select a complete normal state")
    node(current, stat.S_IFLNK, target=selected)
    state = meta / selected
    directory(state)
    raw = record(state / "FORMAT", 256)
    match = re.fullmatch(rb"mailbend-install-state-v1\nkind=(install|rollback)\n"
                         rb"active=(g\.[A-Za-z0-9]{12})\n"
                         rb"previous=(g\.[A-Za-z0-9]{12}|none)\n", raw)
    require(match is not None, "state record grammar")
    kind, active, previous = (value.decode("ascii") for value in match.groups())
    require(previous != active and (kind != "rollback" or previous == "none"),
            "state previous declaration")
    require(set(os.listdir(state)) == {"FORMAT", "active"} |
            ({"previous"} if previous != "none" else set()), "state inventory")
    node(state / "active", stat.S_IFLNK, target="../../generations/" + active)
    if previous != "none":
        node(state / "previous", stat.S_IFLNK, target="../../generations/" + previous)
    for generation in (active,) + ((previous,) if previous != "none" else ()):
        physical = meta / "generations" / generation
        directory(physical)
        require(set(os.listdir(physical)) == {*GENERATION_MEMBERS, "MANIFEST"},
                "generation inventory")
        raw = record(physical / "MANIFEST", 1024)
        lines = raw.split(b"\n")
        require(len(lines) == 8 and lines[0] == b"mailbend-generation-v1"
                and lines[1] == b"generation=" + generation.encode()
                and lines[-1] == b"", "manifest record grammar")
        for name, line in zip(GENERATION_MEMBERS, lines[2:-1]):
            match = re.fullmatch(re.escape(name.encode()) + rb" ([0-9a-f]{64}) 0755", line)
            require(match is not None, "manifest member grammar")
            path = physical / name
            info = node(path, stat.S_IFREG, 0o755)
            require(info.st_size > 0 and os.access(path, os.X_OK), "empty or nonexecutable member")
            identity, _ = opened_file(path, info)
            require(identity["sha256"] == match.group(1).decode(), "manifest mismatch")
            if generation == active:
                key = (info.st_dev, info.st_ino)
                require(key not in seen, f"executable alias: {path}")
                seen.add(key)
                files["bin/" + name] = {**identity, "physical_path": str(path)}
    for relative, before in nodes.items():
        path = root / relative
        after = metadata(path.lstat())
        if "target" in before:
            after["target"] = os.readlink(path)
        require(before == after, f"managed snapshot changed during capture: {relative}")
    return files, {"layout": "managed-v1", "state": selected.removeprefix("states/"),
                   "generation": active, "previous": previous,
                   "physical_generation": str(meta / "generations" / active),
                   "nodes": nodes, "records": records}


def import_boundary(root):
    for directory in (root, root / "tests"):
        for path in directory.iterdir():
            name = path.name.split(".", 1)[0]
            require(name not in sys.stdlib_module_names and name not in sys.builtin_module_names
                    and name not in ("sitecustomize", "usercustomize"),
                    f"ambient standard-library collision: {path}")
    support = root / "tests/scale_support"
    allowed = {root / key for key in PINNED if "/scale_support/" in key}
    allowed.add(support / "v1/ORIGIN.json")
    for path in support.rglob("*"):
        require(not path.is_symlink(), f"snapshot symlink: {path}")
        if path.is_dir():
            require(path == support / "v1" or path.name == "__pycache__",
                    f"unexpected snapshot directory: {path}")
        elif path not in allowed:
            require(path.parent.name == "__pycache__" and path.suffix == ".pyc",
                    f"unexpected snapshot file: {path}")


def preflight(reference, candidate, candidate_sha):
    require(re.fullmatch(r"[0-9a-f]{40}", candidate_sha) is not None,
            "candidate SHA must be an immutable full SHA")
    require(candidate_sha != REFERENCE_SHA, "candidate cannot be its own reference")
    roots = (reference.resolve(), candidate.resolve())
    require(roots[0] != roots[1] and roots[0] not in roots[1].parents
            and roots[1] not in roots[0].parents, "checkouts must be disjoint")
    for root, expected in zip(roots, (REFERENCE_SHA, candidate_sha)):
        require(git(root, "rev-parse", "HEAD").decode().strip() == expected,
                f"wrong source SHA: {root}")
        require(not git(root, "status", "--porcelain", "--untracked-files=no").strip(),
                f"tracked source is dirty: {root}")
        require(git(root, "rev-parse", "refs/tags/scale-reference-v1^{commit}").decode().strip()
                == REFERENCE_SHA, "reference tag does not resolve to fixed SHA")
        import_boundary(root)
        for name, expected_hash in PINNED.items():
            path, _ = regular(root, name)
            require(sha(path.read_bytes()) == expected_hash, f"apparatus changed: {path}")
    original_helpers, candidate_helpers = [], []
    for name in ("scripts/mailbend", *INSTALLERS):
        expected = sha(git(roots[0], "show", f"{REFERENCE_SHA}:{name}"))
        for side, root in enumerate(roots):
            path, _ = regular(root, name)
            actual = sha(path.read_bytes())
            if side == 1 and name == "scripts/mailbend":
                require(actual in (expected, CANDIDATE_LAUNCHER_SHA256,
                                   CANDIDATE_REPORT_LAUNCHER_SHA256, MANAGED_SCRIPT_TUPLE[1]),
                        f"candidate launcher is not a reviewed revision: {path}")
            elif side == 1 and name == "scripts/install.sh":
                require(actual in (expected, CANDIDATE_INSTALLER_SHA256, MANAGED_SCRIPT_TUPLE[0]),
                        f"candidate installer is not a reviewed revision: {path}")
            elif side == 1 and name in INSTALLERS[1:]:
                original_helpers.append(expected)
                candidate_helpers.append(actual)
            else:
                require(actual == expected, f"fixed launcher/installer changed: {path}")
    require(tuple(candidate_helpers) in (tuple(original_helpers), CANDIDATE_HELPER_TUPLE),
            "candidate installer helper tuple is not a reviewed complete revision")
    script_layout(*roots)
    return roots


@contextlib.contextmanager
def comparator(reference):
    # Compile checked source bytes directly; never execute ambient checkout pyc files.
    names = ("scale_support.v1.image_fixtures", "scale_fixtures", "_paired_scale")
    paths = ("tests/scale_support/v1/image_fixtures.py", "tests/scale_fixtures.py",
             "tests/test-scale.py")
    previous = {name: sys.modules.get(name) for name in names}
    try:
        for name, relative in zip(names, paths):
            path = reference / relative
            data = path.read_bytes()
            require(sha(data) == PINNED[relative], f"apparatus changed before import: {path}")
            module = types.ModuleType(name)
            module.__file__ = str(path)
            sys.modules[name] = module
            exec(compile(data, str(path), "exec"), module.__dict__)
        yield module
    finally:
        for name, old in previous.items():
            if old is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = old


def identities(roots, candidate_sha):
    result = {"reference_sha": REFERENCE_SHA, "candidate_sha": candidate_sha, "checkouts": {}}
    seen = set()
    with locked_roots(roots):
        candidate_layout = script_layout(*roots)
        source_before = {(root, name): metadata((root / name).lstat())
                         for side, root in zip(("reference", "candidate"), roots)
                         for name in MANAGED_SCRIPT_PATHS[:3 if side == "candidate"
                             and candidate_layout == "managed-v1" else 2]}
        for side, root, source in zip(("reference", "candidate"), roots, (REFERENCE_SHA, candidate_sha)):
            managed = side == "candidate" and candidate_layout == "managed-v1"
            if managed:
                files, snapshot = managed_snapshot(root, seen)
                names = ("scripts/mailbend", "scripts/install.sh", "scripts/install-layout.sh")
            else:
                require(not (root / ".mailbend-install").exists()
                        and not (root / ".mailbend-install").is_symlink()
                        and not (root / "bin.prev").exists()
                        and not (root / "bin.prev").is_symlink(), "flat outputs required")
                files, snapshot = {}, {"layout": "flat", "bin": metadata((root / "bin").lstat())}
                names = (*EXECUTABLES, "scripts/install.sh")
            for name in names:
                path, info = regular(root, name, executable=name != "scripts/install-layout.sh")
                identity = (info.st_dev, info.st_ino)
                require(identity not in seen, f"executable alias: {path}")
                seen.add(identity)
                files[name], _ = opened_file(path, info)
            root_info = root.lstat()
            root_identity = {"device": root_info.st_dev, "inode": root_info.st_ino,
                             "uid": root_info.st_uid, "mode": root_info.st_mode}
            result["checkouts"][side] = {"root": str(root), "root_identity": root_identity, "source_sha": source,
                                        "files": files, "installation": snapshot}
        for (root, name), before in source_before.items():
            require(metadata((root / name).lstat()) == before,
                    "script changed during identity capture")
    result["adapter_sha256"] = sha(pathlib.Path(__file__).read_bytes())
    return result


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def load_json(path):
    require(path.is_file() and not path.is_symlink(), f"missing or linked report: {path}")
    return json.loads(path.read_text())


def unchanged(roots, candidate_sha, output):
    recorded = load_json(output / "paired-identities.json")
    require(recorded == identities(roots, candidate_sha), "source, profile or executable identities changed")
    return recorded


ADAPTER_VERSION = "alternating-leaders-five-pairs-v2"
SIDES = ("reference", "candidate")
# New absolute per-sample limits, floor(1.25 * fixed-reference baseline logins).
# Provenance: hosted run 41414114062, baseline SHA256 below; not an old harness limit.
HISTORICAL_SHA256 = "92832bc6e9b864dfc2665d5b191b15bb3852c2ddd4b79660d342801f3887e746"
LOGIN_CAPS = {"search-100000": 2, "folders-1000": 2, "folders-5000": 2,
              "read-16mib": 1, "forward-25mib": 6, "thread-1000": 7,
              "classify-images-50": 17}


class SideControl:
    """Charge only active work, including fixture and cleanup time, to a side."""
    def __init__(self, outer, clock=time.monotonic):
        self.outer, self.clock = outer, clock
        self.elapsed = 0.0
        self.started = None

    def used(self):
        return self.elapsed + (self.clock() - self.started if self.started is not None else 0)

    def check(self):
        self.outer.check()
        if self.used() >= 900:
            raise TimeoutError("15-minute active side budget reached")

    def remaining(self, limit):
        self.check()
        return min(limit, 900 - self.used(), self.outer.remaining(limit))

    @contextlib.contextmanager
    def active(self):
        require(self.started is None, "nested side accounting")
        self.check()
        self.started = self.clock()
        try:
            yield self
        finally:
            self.elapsed += self.clock() - self.started
            self.started = None
            self.check()  # A returning call is not accepted after its budget expired.


@contextlib.contextmanager
def route_launcher(harness, reference, launcher):
    """The frozen harness owns fixtures; replace exactly the measured argv[0]."""
    original = harness.measure

    def routed(command, env, work, timeout, control=None):
        require(command and command[0] == str(reference / "scripts/mailbend"),
                "unexpected frozen measurement command")
        return original([str(launcher), *command[1:]], env, work, timeout, control)

    harness.measure = routed
    try:
        yield
    finally:
        harness.measure = original


def absolute_sample(harness, scenario, sample):
    """Ratios cannot excuse both revisions breaching an absolute safety budget."""
    require(harness.valid_sample(sample), f"{scenario.name}: invalid sample")
    for key, ceiling, allow_zero in (("wall_seconds", 90, False),
                                     ("peak_rss_kib", 3145728, False),
                                     ("sampled_group_peak_rss_kib", 3145728, True)):
        value = sample.get(key)
        require(type(value) in (int, float) and math.isfinite(value)
                and (value >= 0 if allow_zero else value > 0) and value <= ceiling,
                f"{scenario.name}: absolute {key} budget exceeded or invalid")
    require(type(sample.get("imap_logins")) is int
            and 0 < sample["imap_logins"] <= LOGIN_CAPS[scenario.name],
            f"{scenario.name}: absolute per-sample login cap exceeded")


def pair_order(index):
    """Alternate the leader, without changing candidate/reference ratio direction."""
    return SIDES if index % 2 == 0 else tuple(reversed(SIDES))


def ratio_gate(harness, reports, order):
    """Validate full reports, then use medians of paired ratios, not ratios of medians."""
    for side in SIDES:
        errors = harness.compare(reports[side], reports[side])
        require(not errors, f"invalid {side} measurement: {errors}")
    require(reports["reference"]["profile"] == reports["candidate"]["profile"],
            "full profiles differ")
    expected = [{"scenario": s.name, "pair": i + 1, "side": side}
                for s in harness.SCENARIOS for i in range(5) for side in pair_order(i)]
    require(order == expected, "missing or out-of-order alternating-leader samples")
    gates = {}
    for scenario in harness.SCENARIOS:
        left = reports["reference"]["scenarios"][scenario.name]["samples"]
        right = reports["candidate"]["scenarios"][scenario.name]["samples"]
        for sample in (*left, *right):
            absolute_sample(harness, scenario, sample)
        metrics = {}
        for key in harness.METRICS:
            ratios = [b[key] / a[key] for a, b in zip(left, right)]
            require(len(ratios) == 5 and all(math.isfinite(x) and x > 0 for x in ratios),
                    "invalid paired ratios")
            median = statistics.median(ratios)
            metrics[key] = {"ratios": ratios, "median_ratio": median, "passed": median <= 1.25}
        gates[scenario.name] = metrics
    return gates


def collect(harness, roots, identity, output, outer):
    controls = {side: SideControl(outer) for side in SIDES}
    reports = {side: {"format": 1, "status": "incomplete", "scenarios": {},
                     "source_commit": identity["checkouts"][side]["source_sha"],
                     "core_sha256": identity["checkouts"][side]["files"]["bin/mailbend-core"]["sha256"],
                     "measurement": "cold launcher, warm OS cache; alternating-leader paired samples",
                     "load_average_start": os.getloadavg()}
               for side in SIDES}
    result = {"status": "failed", "order": [], "adapter_version": ADAPTER_VERSION,
              "adapter_sha256": identity["adapter_sha256"], "identities": identity,
              "median_pair_ratio_budget": 1.25}

    def save():
        for side in SIDES:
            reports[side]["suite_seconds"] = controls[side].used()
            reports[side]["load_average_end"] = os.getloadavg()
            write_json(output / f"{side}-results.json", reports[side])
        write_json(output / "paired-result.json", result)

    try:
        with tempfile.TemporaryDirectory(prefix="mailbend-pair-",
                                        dir=os.environ.get("MAILBEND_TEST_TMPDIR") or None) as tmp:
            root = pathlib.Path(tmp)
            with contextlib.ExitStack() as stack:
                for control in controls.values():
                    stack.enter_context(control.active())
                profile = harness.profile()
                profile = {**profile, "orchestration_version": ADAPTER_VERSION,
                           "orchestration_sha256": identity["adapter_sha256"]}
                certs = harness.certificates(root, harness.clean_env(root), controls["reference"])
            for side in SIDES:
                reports[side]["profile"] = profile.copy()
            result["profile"] = profile
            for scenario in harness.SCENARIOS:
                samples = {side: [] for side in SIDES}
                for index in range(5):
                    for side in pair_order(index):
                        checkout = roots[SIDES.index(side)]
                        work = root / f"{scenario.name}-{index}-{side}"
                        sample = {"status": "failed", "reason": "sample did not complete"}
                        result["order"].append({"scenario": scenario.name, "pair": index + 1, "side": side})
                        try:
                            with controls[side].active():
                                work.mkdir()
                                try:
                                    with route_launcher(harness, roots[0], checkout / "scripts/mailbend"):
                                        sample = harness.run_sample(scenario, work, certs, controls[side])
                                        absolute_sample(harness, scenario, sample)
                                finally:
                                    shutil.rmtree(work)
                        except (Exception, harness.Cancelled) as exc:
                            sample = {**sample, "status": "failed",
                                      "reason": sample.get("reason", type(exc).__name__),
                                      "exception_type": type(exc).__name__}
                            raise
                        finally:
                            samples[side].append(sample)
                            reports[side]["scenarios"][scenario.name] = harness.summarize(samples[side])
                            save()
                        absolute_sample(harness, scenario, sample)
            with contextlib.ExitStack() as stack:
                for control in controls.values():
                    stack.enter_context(control.active())
                require(harness.profile() == {k: v for k, v in profile.items()
                                              if not k.startswith("orchestration_")},
                        "full profile changed during paired run")
            # Historical hardware evidence is informative, never an acceptance gate.
            try:
                historical_path = roots[1] / "tests/scale-baseline.json"
                require(sha(historical_path.read_bytes()) == HISTORICAL_SHA256,
                        "historical evidence hash differs")
                historical = load_json(historical_path)
                require(historical.get("source_commit") == REFERENCE_SHA,
                        "historical evidence source differs")
                plain = {**reports["reference"], "status": "measured",
                         "profile": {k: v for k, v in profile.items()
                                     if not k.startswith("orchestration_")}}
                matching = historical.get("profile") == plain["profile"]
                result["historical_reference_crosscheck"] = {
                    "informational_only": True, "status": "comparable" if matching else "incomparable",
                    "problems": harness.compare(historical, plain) if matching else []}
            except (OSError, ValueError, TypeError, AttributeError) as exc:
                result["historical_reference_crosscheck"] = {
                    "informational_only": True, "status": "unavailable", "reason": type(exc).__name__}
            for side in SIDES:
                controls[side].check()
                reports[side]["status"] = "measured"
            result["gates"] = ratio_gate(harness, reports, result["order"])
            require(all(m["passed"] for case in result["gates"].values() for m in case.values()),
                    "median paired ratio exceeds 1.25")
            result["status"] = "measurements-passed-identity-check-pending"
    except (Exception, harness.Cancelled) as exc:
        result["reason"] = str(exc)
        raise
    finally:
        save()
    return result


def run(args):
    require(not sys.flags.optimize, "optimized Python disables workload assertions")
    roots = preflight(args.reference, args.candidate, args.candidate_sha)
    output = args.output_dir.resolve()
    require(all(output != root and root not in output.parents for root in roots),
            "output directory must be outside both checkouts")
    output.mkdir(parents=True, exist_ok=True)
    if args.phase == "preflight":
        return
    if args.phase == "identities":
        require(not any((output / name).exists() for name in
                        ("paired-identities.json", "reference-results.json", "candidate-results.json", "paired-result.json")),
                "identity or reports already exist")
        write_json(output / "paired-identities.json", identities(roots, args.candidate_sha))
        return
    require(not any((output / name).exists() for name in
                    ("reference-results.json", "candidate-results.json", "paired-result.json")),
            "paired run does not reuse reports or cached acceptance")
    # One frozen reference module, one shared fixture implementation, both binaries.
    with comparator(roots[0]) as harness:
        with harness.RunControl(time.monotonic() + 1800) as outer, locked_roots(roots):
            identity = unchanged(roots, args.candidate_sha, output)
            result = collect(harness, roots, identity, output, outer)
            preflight(args.reference, args.candidate, args.candidate_sha)
            unchanged(roots, args.candidate_sha, output)
            outer.check()
            result["status"] = "passed"
            result["report_sha256"] = {side: sha((output / f"{side}-results.json").read_bytes()) for side in SIDES}
            write_json(output / "paired-result.json", result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("preflight", "identities", "run"))
    parser.add_argument("--reference", type=pathlib.Path, required=True)
    parser.add_argument("--candidate", type=pathlib.Path, required=True)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--output-dir", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        run(args)
        return 0
    except BaseException as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        print(f"paired scale {args.phase} failed: {exc}", file=sys.stderr)
        output = args.output_dir.resolve()
        roots = (args.reference.resolve(), args.candidate.resolve())
        if output.is_dir() and all(output != root and root not in output.parents for root in roots):
            path = output / "paired-result.json"
            result = load_json(path) if path.is_file() else {}
            result.update({"status": "failed", "phase": args.phase, "reason": str(exc),
                           "reference_sha": REFERENCE_SHA, "candidate_sha": args.candidate_sha})
            write_json(path, result)
        return 1


if __name__ == "__main__":
    sys.exit(main())
