#!/usr/bin/env python3
"""Compare parsed image replies with a baseline checkout on this machine."""
import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "tests/perf/image-round-replies.bend"
CASES = (("small", 1, 1000, "small"), ("payload", 100000, 100, "small"),
         ("complex", 1, 100, "complex"), ("complex-payload", 100000, 100, "complex"))


def command(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"command failed: {args!r}\n{result.stdout}{result.stderr}")
    return result.stdout.strip()


def identity(root):
    if command(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"]):
        raise ValueError(f"tracked changes in {root}; commit the measured source first")
    return {"commit": command(["git", "-C", str(root), "rev-parse", "HEAD"]),
            "tools_sha256": hashlib.sha256((root / "src/tools.bend").read_bytes()).hexdigest()}


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"benchmark template no longer contains exactly one {old!r}")
    return source.replace(old, new)


def probe_source(root, prepared, directory):
    relative = os.path.relpath(root / "src", directory)
    prefix = relative if relative.startswith(".") else "./" + relative
    source = TEMPLATE.read_text().replace("../../src/", prefix + "/")
    if prepared:
        source = replace_once(source, "def one(run: T.Run(),", "def one(run: Result<&2, &2, String, T.PartReply>,")
        source = replace_once(source, "T.part_bytes(run, uid, 42,", "T.part_prepared(run, uid,")
        marker = "def repeat("
        source = replace_once(source, marker, """def round(run: T.Run(), +size: U32) -> U32:
  +parsed = T.part_prepare(run, 42)
  (one(parsed, 1, size) + one(parsed, 2, size) + one(parsed, 3, size) +
    one(parsed, 4, size) : U32)

""" + marker)
        source = replace_once(source, "count = (one(run, 1, size) + one(run, 2, size) + one(run, 3, size) +\n        one(run, 4, size) : U32)", "count = round(run, size)")
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    roots = {"baseline": args.baseline.resolve(), "candidate": args.candidate.resolve()}
    report = {"sources": {name: identity(root) for name, root in roots.items()},
              "system": platform.platform(), "load_average": os.getloadavg(),
              "bend": command(["bend", "version"]), "clang": command(["clang", "--version"]),
              "template_sha256": hashlib.sha256(TEMPLATE.read_bytes()).hexdigest(), "cases": []}
    with ExitStack() as stack:
        binaries = {}
        for name, root in roots.items():
            build = root / "build"
            build.mkdir(exist_ok=True)
            work = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="image-replies-", dir=build)))
            source = probe_source(root, name == "candidate", work)
            path = work / f"{name}.bend"
            path.write_text(source)
            binary = work / name
            command(["bend", str(path), "-o", str(binary)], timeout=300)
            report["sources"][name].update(probe_sha256=hashlib.sha256(source.encode()).hexdigest(),
                binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
            binaries[name] = binary
        for name, size, rounds, shape in CASES:
            samples = {side: [] for side in binaries}
            for pair in range(5):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for side in order:
                    before = resource.getrusage(resource.RUSAGE_CHILDREN)
                    start = time.perf_counter()
                    output = command([str(binaries[side]), str(size), str(rounds), shape], timeout=90)
                    elapsed = time.perf_counter() - start
                    after = resource.getrusage(resource.RUSAGE_CHILDREN)
                    if output != str(4 * size * rounds):
                        raise ValueError(f"{name} {side}: wrong decoded-byte count {output}")
                    samples[side].append({"wall_seconds": elapsed, "output_bytes": int(output),
                        "user_seconds": after.ru_utime - before.ru_utime,
                        "system_seconds": after.ru_stime - before.ru_stime})
            summary = {side: {"median_ms_per_round": statistics.median(
                row["wall_seconds"] for row in rows) * 1000 / rounds,
                "range_ms_per_round": [min(row["wall_seconds"] for row in rows) * 1000 / rounds,
                                       max(row["wall_seconds"] for row in rows) * 1000 / rounds]}
                for side, rows in samples.items()}
            report["cases"].append({"name": name, "bytes_per_slot": size, "rounds_per_sample": rounds,
                                    "samples": samples, "summary": summary})
            print(name, json.dumps(summary), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
