#!/usr/bin/env python3
"""Run public thread scenarios on a built immutable checkout."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def expected_failures(mode):
    result = set()
    for checked in (False, True):
        for command in ("EXAMINE#1", "FETCH#1", "LIST#1"):
            if mode in ("baseline", "unscoped-caps"):
                result.add(f"thread reply scope: capability at {command}, checked={checked}"
                           " requests only the advertised role lookup and required thread reads")
        for command in ("EXAMINE#1", "FETCH#1", "CAPABILITY#1"):
            if mode in ("baseline", "unscoped-folders"):
                prefix = f"thread reply scope: folders at {command}, checked={checked}"
                result.add(prefix + " uses only the corresponding discovery replies")
                result.add(prefix + " requests only the advertised role lookup and required thread reads")
        if mode == "empty-caps":
            result.add(f"thread reply scope: capability at CAPABILITY#1, checked={checked}"
                       " requests only the advertised role lookup and required thread reads")
        if mode == "empty-folders":
            for kind, command in (("capability", "EXAMINE#1"), ("capability", "FETCH#1"),
                                  ("capability", "LIST#1"), ("folders", "LIST#1")):
                prefix = f"thread reply scope: {kind} at {command}, checked={checked}"
                result.add(prefix + " uses only the corresponding discovery replies")
                result.add(prefix + " requests only the advertised role lookup and required thread reads")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--mode", choices=("baseline", "candidate", "unscoped-caps",
                                         "unscoped-folders", "empty-caps", "empty-folders"), required=True)
    parser.add_argument("--existing", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    sys.path.insert(0, str(root / "tests"))
    spec = importlib.util.spec_from_file_location("discovery_e2e", root / "tests/test-e2e.py")
    suite = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(suite)
    transport = "mcp" if os.environ.get("MAILBEND_TEST_MCP") == "1" else "cli"
    with tempfile.TemporaryDirectory(prefix="discovery-replies-") as work:
        subprocess.run(["sh", str(root / "tests/gen-test-certs.sh"), str(Path(work) / "certs")],
                       check=True, capture_output=True, timeout=60)
        if args.existing:
            for scenario in (suite.threads, suite.thread_discovery, suite.thread_discovery_failures,
                             suite.thread_discovery_literals, suite.archive_threads):
                scenario(work)
            existing_failures = [name for name, ok in suite.results if not ok]
            if existing_failures:
                raise SystemExit("existing thread scenarios failed: " + json.dumps(existing_failures))
        start = len(suite.results)
        suite.thread_discovery_reply_scope(work)
        failures = [name for name, ok in suite.results[start:] if not ok]
        if any(suite.PASSWORD in output for output in suite.outputs):
            raise SystemExit("synthetic password leaked in tool output")
        expected = expected_failures(args.mode)
        print(json.dumps({"mode": args.mode, "transport": transport,
                          "checks": len(suite.results), "failures": failures}, sort_keys=True))
        if len(failures) != len(expected) or set(failures) != expected:
            raise SystemExit("unexpected failure set: " + json.dumps({
                "missing": sorted(expected - set(failures)), "extra": sorted(set(failures) - expected)}))
        print(f"PASS {args.mode} {transport}: {len(failures)} intended failures; no other failures or password leak")


if __name__ == "__main__":
    main()
