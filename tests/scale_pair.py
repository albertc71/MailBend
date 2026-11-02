#!/usr/bin/env python3
"""Verify a fixed-reference, same-runner scale pair without changing measurements."""
import argparse
import contextlib
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
    for name in ("scripts/mailbend", *INSTALLERS):
        expected = sha(git(roots[0], "show", f"{REFERENCE_SHA}:{name}"))
        for root in roots:
            path, _ = regular(root, name)
            require(sha(path.read_bytes()) == expected, f"fixed launcher/installer changed: {path}")
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
    for side, root, source in zip(("reference", "candidate"), roots, (REFERENCE_SHA, candidate_sha)):
        files = {}
        for name in EXECUTABLES:
            path, info = regular(root, name, executable=True)
            identity = (info.st_dev, info.st_ino)
            require(identity not in seen, f"executable alias: {path}")
            seen.add(identity)
            files[name] = {"sha256": sha(path.read_bytes()), "device": info.st_dev,
                           "inode": info.st_ino, "size": info.st_size, "mode": info.st_mode}
        result["checkouts"][side] = {"root": str(root), "source_sha": source, "files": files}
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


ADAPTER_VERSION = "abab-five-pairs-v1"
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


def ratio_gate(harness, reports, order):
    """Validate full reports, then use medians of paired ratios, not ratios of medians."""
    for side in SIDES:
        errors = harness.compare(reports[side], reports[side])
        require(not errors, f"invalid {side} measurement: {errors}")
    require(reports["reference"]["profile"] == reports["candidate"]["profile"],
            "full profiles differ")
    expected = [{"scenario": s.name, "pair": i + 1, "side": side}
                for s in harness.SCENARIOS for i in range(5) for side in SIDES]
    require(order == expected, "missing or out-of-order ABAB samples")
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
                     "measurement": "cold launcher, warm OS cache; ABAB paired samples",
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
                    for side, checkout in zip(SIDES, roots):
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
        with harness.RunControl(time.monotonic() + 1800) as outer:
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
