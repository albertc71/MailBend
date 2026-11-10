#!/usr/bin/env python3
"""Compile isolated observer mutations and restore the verified candidate."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(root, *command, env=None, timeout=300):
    subprocess.run(command, cwd=root, env=env, check=True, timeout=timeout)


def check_transports(root, driver, mode, existing=False):
    for mcp in ("0", "1"):
        env = dict(os.environ, MAILBEND_TEST_MCP=mcp)
        command = [sys.executable, "-I", "-B", str(driver), "--root", str(root), "--mode", mode]
        if existing:
            command.append("--existing")
        run(root, *command, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--source-sha256", required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    source = root / "src/tools.bend"
    original = source.read_text(encoding="utf-8")
    if digest(source) != args.source_sha256:
        raise SystemExit("candidate source identity mismatch")
    start = original.index("def thread_start.put(")
    end = original.index("\ndef thread_start(", start)
    body = original[start:end]
    driver = Path(__file__).resolve().with_name("discovery_reply_controls.py")
    core = root / "bin/mailbend-core"
    saved = root / "bin/mailbend-core.discovery-saved"
    core_digest = digest(core)
    helpers = {name: digest(root / "bin" / name) for name in (
        "mailbend-tls", "mailbend-attach", "mailbend-stdio", "mailbend-typesafe")}
    shutil.copy2(core, saved)
    variants = (
        ("unscoped-caps", "I.replies(lines, 3)", "lines"),
        ("unscoped-folders", "I.replies(lines, 4)", "lines"),
        ("empty-caps", "I.caps(I.replies(lines, 3))", "[]"),
        ("empty-folders", "I.folders(I.replies(lines, 4))", "[]"),
    )
    try:
        for mode, before, after in variants:
            if body.count(before) != 1:
                raise SystemExit("mutation target is not unique: " + mode)
            changed = body.replace(before, after)
            if mode.startswith("empty-"):
                changed = changed.replace("+lines: List<&2, I.RLine>", "lines: List<&2, I.RLine>")
            source.write_text(original[:start] + changed + original[end:], encoding="utf-8")
            print(f"MUTATION {mode} source_sha256={digest(source)}", flush=True)
            run(root, "git", "diff", "--", "src/tools.bend")
            built = root / "bin/mailbend-core.discovery-new"
            run(root, "bend", "main.bend", "-o", str(built), timeout=600)
            os.replace(built, core)
            print(f"MUTATION {mode} core_sha256={digest(core)}", flush=True)
            check_transports(root, driver, mode)
            if any(digest(root / "bin" / name) != value for name, value in helpers.items()):
                raise SystemExit("a mutation changed a native helper")
    finally:
        source.write_text(original, encoding="utf-8")
        os.replace(saved, core)
    if digest(source) != args.source_sha256 or digest(core) != core_digest:
        raise SystemExit("candidate source or executable was not restored")
    check_transports(root, driver, "candidate", existing=True)
    print(f"PASS restored candidate source={digest(source)} core={digest(core)}", flush=True)


if __name__ == "__main__":
    main()
