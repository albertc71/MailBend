#!/usr/bin/env python3
"""The helper's MAX_REQUEST is the cap line Bend prints, and the schema names
every image skip reason."""

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
REASONS = (
    "format",
    "animated",
    "dimensions",
    "file_size",
    "over_count",
    "over_budget",
    "unreadable",
    "ref",
    "refused",
)


def bend_max():
    env = dict(**{k: v for k, v in __import__("os").environ.items()})
    env["BEND_NO_TELEMETRY"] = "1"
    proc = subprocess.run(
        ["bend", str(ROOT / "tests" / "unit" / "image.bend")],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    text = proc.stdout + proc.stderr
    match = re.search(r"^caps .* max (\d+)$", text, re.M)
    if proc.returncode != 0 or not match:
        sys.exit(f"bend image caps failed:\n{text}")
    return int(match.group(1)), text


def rust_max():
    src = (ROOT / "native" / "mailbend-typesafe" / "src" / "settings.rs").read_text()
    match = re.search(r"const MAX_REQUEST: usize = ([0-9_]+);", src)
    if not match:
        sys.exit("MAX_REQUEST is not a single integer")
    return int(match.group(1).replace("_", ""))


def main():
    printed, text = bend_max()
    rust = rust_max()
    if printed != rust:
        sys.exit(f"MAX_REQUEST {rust} != bend max {printed}")
    schema = (ROOT / "src" / "schema.bend").read_text()

    def has(name):
        return f'"{name}"' in schema or f'\\"{name}\\"' in schema

    missing = [name for name in REASONS if not has(name)]
    if missing:
        sys.exit("schema omits image reasons: " + ", ".join(missing))
    if "image_notice" not in schema or not has("images"):
        sys.exit("schema omits images or image_notice")
    print(f"image budget {printed} matches MAX_REQUEST")


if __name__ == "__main__":
    main()
