"""Run exact source mutations against PROOF.bend without changing the checkout."""

import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def check(root):
    return subprocess.run(["bend", "PROOF.bend", "--check-only"], cwd=root,
                          capture_output=True, text=True, timeout=300,
                          env=dict(os.environ, BEND_NO_TELEMETRY="1"))


def require_baseline(result, label):
    require(result.returncode == 0 and "ALL PROOFS CHECK" in result.stdout
            and "SOME PROOFS FAIL" not in result.stdout + result.stderr,
            f"{label}: baseline did not pass\n{result.stdout}{result.stderr}")


def require_rejection(result, mutation):
    output = result.stdout + result.stderr
    location = re.search(r"^Location: (\S+)", output, re.M)
    expected = mutation["proof"].split("#", 1)[1]
    allowed = {expected, expected.removeprefix("Laws.")}
    require(result.returncode != 0 and "SOME PROOFS FAIL" in output
            and "ALL PROOFS CHECK" not in output
            and location is not None and location[1] in allowed
            and re.search(r"^- expected\s*:", output, re.M)
            and re.search(r"^- observed\s*:", output, re.M)
            and not re.search(r"consumed more than once|a defined name|a term \(|"
                              r"a live scrutinee|can.t be matched|Error parsing", output),
            f"{mutation['id']}: expected semantic rejection at {expected}\n{output}")


def source_files(root):
    return sorted({root / "LAWS.bend", root / "PROOF.bend",
                   *(root / "src").rglob("*.bend"), *(root / "tests/formal").rglob("*.bend")})


def fingerprint(root):
    return {p.relative_to(root): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files(root)}


def run_mutations(root, mutations, run_check=check):
    before = fingerprint(root)
    require_baseline(run_check(root), "checkout")
    with tempfile.TemporaryDirectory(prefix="mailbend-claim-mutations-") as directory:
        copy = Path(directory)
        for relative in before:
            destination = copy / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((root / relative).read_bytes())
        require_baseline(run_check(copy), "copied checkout")
        failures = []
        for mutation in mutations:
            relative = Path(mutation["path"])
            require(relative in before and relative.parts[0] == "src",
                    f"{mutation['id']}: mutation target is not a copied production module")
            target = copy / relative
            original = target.read_text(encoding="utf-8")
            require(mutation["before"] and original.count(mutation["before"]) == 1
                    and mutation["before"] != mutation["after"],
                    f"{mutation['id']}: mutation target must occur exactly once and change")
            target.write_text(original.replace(mutation["before"], mutation["after"]), encoding="utf-8")
            try:
                require_rejection(run_check(copy), mutation)
                print(f"PASS {mutation['id']}: rejected at {mutation['proof']}", flush=True)
            except ValueError as error:
                failures.append(str(error))
                print(f"FAIL {mutation['id']}: {str(error).splitlines()[0]}", flush=True)
            finally:
                target.write_text(original, encoding="utf-8")
        require_baseline(run_check(copy), "restored copy")
        require(fingerprint(copy) == before, "restored copy differs from the checkout")
    require(fingerprint(root) == before, "checkout changed during mutation checks")
    require(not failures, "\n\n".join(failures))
    print(f"PASS {len(mutations)}/{len(mutations)} claim mutations rejected; checkout unchanged", flush=True)
