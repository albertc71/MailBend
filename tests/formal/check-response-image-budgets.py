#!/usr/bin/env python3
"""Require the universal budget proofs to reject two broken production steps."""

import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENTRY = "tests/formal/budget-proofs.bend"
MUTATIONS = (
    (
        "prefix-keeps-over-budget-scalar",
        "src/response.bend",
        '    case False{}:\n      Prefix{"", left}',
        '    case False{}:\n      Prefix{SCon{c, tail}, left}',
        "prefix_conserves",
    ),
    (
        "image-admission-ignores-count",
        "src/image.bend",
        "admit.count(U32.is_zero(count), still, count, bytes)",
        "admit.count(False{}, still, count, bytes)",
        "admit_conserves",
    ),
)


def check(root):
    return subprocess.run(
        ["bend", ENTRY, "--check-only"],
        cwd=root,
        capture_output=True,
        text=True,
        timeout=300,
        env=dict(os.environ, BEND_NO_TELEMETRY="1"),
    )


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def fingerprint():
    paths = sorted((ROOT / "src").glob("*.bend"))
    paths += sorted((ROOT / "tests/formal").glob("budget-*.bend"))
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def main():
    before = fingerprint()
    original = check(ROOT)
    require(original.returncode == 0 and "ALL PROOFS CHECK" in original.stdout,
            ("baseline", original.stdout, original.stderr))
    print("PASS universal budget proofs: ALL PROOFS CHECK")
    for name, path, old, new, proof in MUTATIONS:
        with tempfile.TemporaryDirectory(prefix="mailbend-budget-mutation-") as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "src", root / "src")
            (root / "tests/formal").mkdir(parents=True)
            for source in (ROOT / "tests/formal").glob("budget-*.bend"):
                shutil.copy2(source, root / "tests/formal" / source.name)
            target = root / path
            source = target.read_text(encoding="utf-8")
            require(source.count(old) == 1, (name, "mutation target not found once"))
            target.write_text(source.replace(old, new), encoding="utf-8")
            result = check(root)
            output = result.stdout + result.stderr
            location = re.search(r"^Location: (\S+)", output, re.MULTILINE)
            require(result.returncode != 0 and "SOME PROOFS FAIL" in output,
                    (name, "mutant not rejected by the checker", output))
            require(location is not None and proof in location.group(1),
                    (name, "failure did not reach the expected universal proof", output))
            print(f"PASS rejected {name}: universal proof {location.group(1)} fails")
    require(before == fingerprint(), "checkout changed")
    print("PASS checkout unchanged")


if __name__ == "__main__":
    main()
