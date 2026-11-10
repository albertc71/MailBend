#!/usr/bin/env python3
"""Check the retained thread baseline, semantic controls and bounded paired timings."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import resource
import shutil
import signal
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "5ff799d094fd08078391c33218dc2a9ef598494b"
THREAD_BLOB = "f02c2bb36b2faac9946270985cd0061e76d16649"
OUTPUT_LIMIT = 16 * 1024 * 1024
START = time.monotonic()
CANCELLED = 0
REPORT = {"baseline": BASELINE, "commands": [], "controls": [], "cases": []}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def interrupted(signum, _frame):
    global CANCELLED
    CANCELLED = signum


def check_interruption():
    if CANCELLED:
        raise InterruptedError(f"interrupted by signal {CANCELLED}")


def limits():
    resource.setrlimit(resource.RLIMIT_CPU, (180, 180))
    resource.setrlimit(resource.RLIMIT_FSIZE, (64 * 1024**2, 64 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def group_snapshot(pgid):
    rss, leader, live = 0, False, False
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            fields = (entry / "stat").read_bytes().rsplit(b")", 1)[1].split()
        except (FileNotFoundError, ProcessLookupError):
            continue
        if int(fields[2]) == pgid:
            leader |= int(entry.name) == pgid
            live |= fields[0] not in (b"Z", b"X")
            rss += max(0, int(fields[21])) * os.sysconf("SC_PAGE_SIZE") // 1024
    if not leader:
        raise RuntimeError("owned process-group leader is not observable")
    return rss, live


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
        deadline = time.monotonic() + 1
        while group_snapshot(process.pid)[1]:
            if time.monotonic() >= deadline:
                raise RuntimeError("owned process group did not stop")
            time.sleep(0.01)
    finally:
        process.wait(timeout=5)


def run(argv, cwd=ROOT, seconds=90):
    check_interruption()
    remaining = 900 - (time.monotonic() - START)
    if remaining <= 0:
        raise RuntimeError("thread comparison total deadline exhausted")
    seconds = min(seconds, remaining)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("MAILBEND_", "TYPESAFE_"))}
    env["BEND_NO_TELEMETRY"] = "1"
    with tempfile.TemporaryDirectory(prefix="thread-command-") as name:
        directory = Path(name)
        out, err, timing = (directory / part for part in ("out", "err", "time"))
        with out.open("wb") as stdout, err.open("wb") as stderr:
            before = time.monotonic()
            sampled_peak = 0
            process = subprocess.Popen(
                ["/usr/bin/time", "-f", "%e %U %S %M", "-o", str(timing), *argv],
                cwd=cwd, env=env, stdout=stdout, stderr=stderr,
                start_new_session=True, preexec_fn=limits)
            try:
                while True:
                    check_interruption()
                    rss, _ = group_snapshot(process.pid)
                    sampled_peak = max(sampled_peak, rss)
                    if rss > 2 * 1024**2:
                        raise RuntimeError("sampled process-group RSS exceeded 2 GiB")
                    state = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG)
                    if state is not None:
                        break
                    if time.monotonic() - before > seconds:
                        raise RuntimeError(f"incomplete evidence: command exceeded {seconds:.1f}s")
                    if out.stat().st_size > OUTPUT_LIMIT or err.stat().st_size > OUTPUT_LIMIT:
                        raise RuntimeError("command output exceeded 16 MiB")
                    time.sleep(0.02)
            finally:
                # Keep the unreaped session leader until its owned group is signalled.
                stop_group(process)
                code = process.returncode
            elapsed = time.monotonic() - before
        check_interruption()
        if out.stat().st_size > OUTPUT_LIMIT or err.stat().st_size > OUTPUT_LIMIT:
            raise RuntimeError("command output exceeded 16 MiB")
        output, errors = out.read_bytes(), err.read_bytes()
        record = {"argv": argv, "supervisor_wall_seconds": elapsed, "exit": code,
                  "output_bytes": len(output), "output_sha256": digest(output),
                  "sampled_group_peak_rss_kib": sampled_peak}
        REPORT["commands"].append(record)
        if code != 0 or errors:
            raise RuntimeError(f"command failed: {record}; diagnostic={errors[:2048]!r}")
        fields = timing.read_text().split()
        if len(fields) != 4:
            raise RuntimeError("missing GNU time measurements")
        record.update(wall_seconds=float(fields[0]), user_seconds=float(fields[1]), system_seconds=float(fields[2]),
                      peak_rss_kib=int(fields[3]))
        if not all(math.isfinite(float(value)) and float(value) >= 0 for value in fields):
            raise RuntimeError("invalid GNU time measurements")
        if record["peak_rss_kib"] > 2 * 1024**2:
            raise RuntimeError("command RSS exceeded 2 GiB")
        return output, record


def expected(path):
    return b"".join(line[2:] + b"\n" for line in path.read_bytes().splitlines()
                    if line.startswith(b"#|"))


def reference_source(source):
    import re
    text = source[source.index("# Whether `a` comes no later"):]
    for name in ("Node", "Placed", "node_time", "node_uid", "node_id", "parent_ids", "own_id"):
        text = re.sub(r"\b" + name + r"\b", "T." + name, text)
    return ("# Retained order implementation from " + BASELINE + ".\n"
            "# Only Node/Placed and unchanged node accessors are qualified through T.\n\n"
            "import Base\nimport ../../src/codec.bend as C\n"
            "import ../../src/thread.bend as T\n\n" + text)


def provenance(baseline):
    REPORT["host"] = {"platform": platform.platform(), "cpus": os.cpu_count(),
                      "load_average": os.getloadavg(), "rss_poll_seconds": 0.02,
                      "sampled_group_rss_limit_kib": 2 * 1024**2}
    version, _ = run(["bend", "version"], seconds=10)
    REPORT["bend"] = version.decode().strip()
    if REPORT["bend"] != "bend 2.0.35":
        raise RuntimeError("unexpected Bend toolchain")
    clang, _ = run(["clang", "--version"], seconds=10)
    REPORT["clang"] = clang.decode().strip()
    source = (baseline / "src/thread.bend").read_bytes()
    blob = hashlib.sha1(b"blob " + str(len(source)).encode() + b"\0" + source).hexdigest()
    if blob != THREAD_BLOB:
        raise RuntimeError("baseline source identity mismatch")
    retained = ROOT / "tests/thread-support/reference.bend"
    if retained.read_text().rstrip() != reference_source(source.decode()).rstrip():
        raise RuntimeError("retained reference differs beyond its documented adaptation")
    candidate = (ROOT / "src/thread.bend").read_text()
    original = source.decode()
    if candidate[:candidate.index("# An ID is present")] != original[:original.index("# Walks `ps` until")]:
        raise RuntimeError("shared reference dependencies changed before the ordering helpers")
    def ids_of(text):
        return text[text.index("def ids_of("):text.index("# The thread in order")]
    if ids_of(candidate) != ids_of(original):
        raise RuntimeError("ids_of reference dependency changed")
    REPORT["source_sha256"] = {str(path.relative_to(ROOT)): digest(path.read_bytes())
        for path in [ROOT / "src/thread.bend", retained,
                     ROOT / "tests/thread-support/fixtures.bend",
                     ROOT / "tests/perf/thread-index.bend", Path(__file__)]}
    head, _ = run(["git", "rev-parse", "HEAD"], seconds=5)
    REPORT["candidate"] = head.decode().strip()
    for path in ("scripts/install-bend.sh", "src/codec.bend", "src/imap.bend", "src/mime.bend"):
        if (ROOT / path).read_bytes() != (baseline / path).read_bytes():
            raise RuntimeError(f"comparison dependency changed: {path}")


def controls():
    unit = Path("tests/unit/thread-index.bend")
    wanted = expected(ROOT / unit)
    output, _ = run(["bend", str(unit)], seconds=90)
    if output != wanted:
        raise RuntimeError(f"characterization mismatch: {output[:2048]!r}")
    mutations = (
        ("unique-membership", "Map.has(&2, Bool, present, d)", "Map.get(Bool, False{}, present, d)"),
        ("shared-ids", "Map.set(&2, Bool, present2, id, seen)", "Map.set(&2, Bool, present2, id, False{})"),
        ("shared-saturation", "(present2, seen) = Map.has(&2, Bool, present, id)\n      thread_order.present(t, Map.set(&2, Bool, present2, id, seen))",
         "(present2, seen) = Map.get(Bool, True{}, present, id)\n      thread_order.present(t, Map.set(&2, Bool, present2, id, Bool.not(seen)))"),
        ("empty-ids", "thread_order.present(ids_of(sorted),", 'thread_order.present("" <> "" <> ids_of(sorted),'),
        ("cycle-cut", 'Bool.pick(String, cycle || shared, "", p)', 'Bool.pick(String, shared, "", p)'),
        ("cycle-fallback", 'Bool.pick(String, cycle || shared, "", p)',
         'Bool.pick(String, cycle || shared, Maybe.default(&2, String, List.get(&2, String, parent_ids(n), 1n), ""), p)'),
        ("candidate-order", "parent_in(parent_ids(n), present, id)",
         "parent_in(List.reverse(&2, String, parent_ids(n)), present, id)"),
        ("output-order", "List.reverse(&2, Placed, ps)", "ps"),
        ("node-payload", "Placed{n, parent}", "Placed{mutation_node(n), parent}"),
    )
    source = (ROOT / "src/thread.bend").read_text()
    assertions = {
        "unique-membership": (b"cycle does not retry References", 1),
        "shared-ids": (b"shared IDs keep no parent, but remain candidates", 1),
        "shared-saturation": (b"shared IDs keep no parent, but remain candidates", 1),
        "empty-ids": (b"missing IDs are not shared", 1),
        "cycle-cut": (b"cycle does not retry References", 1),
        "cycle-fallback": (b"cycle does not retry References", 1),
        "candidate-order": (b"cycle does not retry References", 1),
        "output-order": (b"cycle does not retry References", 1),
        "node-payload": (b"baseline projections", 2),
    }
    for name, old, new in mutations:
        if source.count(old) != 1:
            raise RuntimeError(f"mutation target mismatch: {name}")
        with tempfile.TemporaryDirectory(prefix="thread-mutation-") as temp:
            copy = Path(temp)
            shutil.copytree(ROOT / "src", copy / "src")
            shutil.copytree(ROOT / "tests/thread-support", copy / "tests/thread-support")
            (copy / unit).parent.mkdir(parents=True)
            shutil.copyfile(ROOT / unit, copy / unit)
            changed = source.replace(old, new)
            if name == "node-payload":
                helper = '''def mutation_node(n: Node) -> Node:
  Node{folder, generation, I.Msg{uid, flags, date, size, headers, body, tree},
    time, id, replies, refs} = n
  Node{folder, generation, I.Msg{uid, flags, date, size, headers, body ++ "!", tree},
    time, id, replies, refs}

'''
                if changed.count("def thread_order.step(") != 1:
                    raise RuntimeError("payload mutation insertion point changed")
                changed = changed.replace("def thread_order.step(", helper + "def thread_order.step(")
            (copy / "src/thread.bend").write_text(changed)
            actual, _ = run(["bend", str(unit)], cwd=copy, seconds=90)
            if actual == wanted or len(actual.splitlines()) != len(wanted.splitlines()):
                raise RuntimeError(f"mutation was not a semantic mismatch: {name}")
            label, offset = assertions[name]
            position = wanted.splitlines().index(label) + offset
            want_line, actual_line = wanted.splitlines()[position], actual.splitlines()[position]
            if want_line == actual_line:
                raise RuntimeError(f"mutation missed its intended assertion: {name}")
            REPORT["controls"].append({"mutation": name, "rejected": True,
                "assertion": label.decode(), "expected": want_line.decode(), "actual": actual_line.decode(),
                "output_sha256": digest(actual), "expected_sha256": digest(wanted)})


def compare():
    with tempfile.TemporaryDirectory(prefix="thread-binary-") as temp:
        binary = Path(temp) / "thread-index"
        run(["bend", "tests/perf/thread-index.bend", "-o", str(binary)], seconds=180)
        REPORT["binary_sha256"] = digest(binary.read_bytes())
        output, _ = run([str(binary), "check"], seconds=90)
        if output != b"equivalence cases=3770 failures=0\n":
            raise RuntimeError(f"equivalence failed: {output!r}")
        REPORT["equivalence_cases"] = 3770
        for size, shape in ((10, "chain"), (100, "chain"), (1000, "chain"),
                            (1000, "cycle"), (1000, "prefix")):
            rows = {"baseline": [], "candidate": []}
            for pair in range(5):
                outputs = {}
                for side in (("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")):
                    outputs[side], sample = run([str(binary), side, str(size), shape], seconds=15)
                    rows[side].append(sample)
                if (not outputs["baseline"] or b"EXHAUSTED" in outputs["baseline"] or
                        outputs["baseline"] != outputs["candidate"]):
                    raise RuntimeError(f"paired output mismatch: {size} {shape} pair {pair}")
            REPORT["cases"].append({"size": size, "shape": shape, "pairs": 5, "samples": rows,
                "median_seconds": {side: statistics.median(r["wall_seconds"] for r in samples)
                                   for side, samples in rows.items()},
                "range_seconds": {side: [min(r["wall_seconds"] for r in samples),
                                          max(r["wall_seconds"] for r in samples)]
                                  for side, samples in rows.items()}})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    args = parser.parse_args()
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        provenance(args.baseline.resolve())
        controls()
        compare()
        check_interruption()
        REPORT["status"] = "passed"
    except Exception as exc:
        REPORT["status"] = "failed"
        REPORT["reason"] = str(exc)
        raise
    finally:
        print(json.dumps(REPORT, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
