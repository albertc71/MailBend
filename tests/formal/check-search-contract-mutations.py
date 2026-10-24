#!/usr/bin/env python3
"""Require real Bend checks to reject cursor, guard and fetch-renderer mutations.

Copies production Bend modules and the cursor test into a temporary directory;
the checkout is never modified. Baseline output must match its checked-in
expectations. Changing the production U32.is_lt boundary to U32.is_le must
still compile/run, but must violate the tested exclusion of the boundary UID.
Also require the exact continuation-plan law to reject a wrong caller mailbox
and a mailbox switch after the UIDVALIDITY guard. This covers plan_search_page;
it does not strengthen the generic Ops.pinned classifier for unrelated plans.
This source mutation check complements, rather than proves, universal laws.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def run(root, entry="tests/unit/search-cursor.bend"):
    env = dict(os.environ, BEND_NO_TELEMETRY="1")
    return subprocess.run(["bend", entry], cwd=root,
                          capture_output=True, text=True, env=env, timeout=120)


def main():
    expected = "".join(line[2:] + "\n" for line in
                       (ROOT / "tests/unit/search-cursor.bend").read_text(encoding="utf-8").splitlines()
                       if line.startswith("#|"))
    baseline = run(ROOT)
    require(baseline.returncode == 0 and baseline.stdout == expected,
            ("baseline cursor property test failed", baseline.stdout, baseline.stderr))
    with tempfile.TemporaryDirectory(prefix="mailbend-search-mutation-") as directory:
        root = Path(directory)
        shutil.copytree(ROOT / "src", root / "src")
        # Root proofs may import shared models from this directory. Exclude
        # scratch projects if TMPDIR happens to point into the source tree.
        shutil.copytree(ROOT / "tests/formal", root / "tests/formal",
                        ignore=shutil.ignore_patterns("__pycache__", "mailbend-search-mutation-*"))
        (root / "tests/unit").mkdir(parents=True)
        shutil.copy2(ROOT / "tests/unit/search-cursor.bend", root / "tests/unit/search-cursor.bend")
        source = root / "src/search-cursor.bend"
        text = source.read_text(encoding="utf-8")
        old, new = "U32.is_lt(u, before)", "U32.is_le(u, before)"
        require(text.count(old) == 1, "production boundary moved: update this mutation explicitly")
        source.write_text(text.replace(old, new), encoding="utf-8")
        broken = run(root)
        require(broken.returncode == 0, ("mutation did not run", broken.stdout, broken.stderr))
        require(broken.stdout != expected and "[4294967295,2,1]\n" in broken.stdout,
                ("inclusive production boundary was not detected", broken.stdout))
        source.write_text(text, encoding="utf-8")
        for name in ("LAWS.bend", "PROOF.bend"):
            shutil.copy2(ROOT / name, root / name)
        baseline_proof = run(root, "PROOF.bend")
        require(baseline_proof.returncode == 0 and "ALL PROOFS CHECK" in baseline_proof.stdout,
                (baseline_proof.stdout, baseline_proof.stderr))
        ops = root / "src/ops.bend"
        original = ops.read_text(encoding="utf-8")
        plan = "[I.CExamine{mbox}, I.CExpect{I.uidv_line(uidv)}, I.CSearch{keys}]"
        require(original.count(plan) == 1, "continuation plan moved: update mutations explicitly")
        mutations = {
            "wrong caller mailbox": plan.replace("CExamine{mbox}", 'CExamine{"Other"}'),
            "mailbox switch after guard": plan.replace("I.CSearch{keys}",
                                                       'I.CExamine{"Other"}, I.CSearch{keys}'),
        }
        for name, replacement in mutations.items():
            ops.write_text(original.replace(plan, replacement), encoding="utf-8")
            rejected = run(root, "PROOF.bend")
            require(rejected.returncode != 0 and "search_continuation_pins_identity" in (
                rejected.stdout + rejected.stderr), (name, rejected.stdout, rejected.stderr))
            print(f"PASS actual Bend plan mutation rejected by exact identity law: {name}")
        ops.write_text(original, encoding="utf-8")
        imap = root / "src/imap.bend"
        renderer = imap.read_text(encoding="utf-8")
        render_mutations = (
            ('"BODY.PEEK[HEADER.FIELDS (" ++ header_fields() ++ ")]"',
             '"BODY.PEEK[HEADER.FIELDS (" ++ header_fields() ++ ")] BODY[]"',
             "search_headers_render_exactly"),
            ('"BODY.PEEK[]<0." ++ U32.show(max) ++ ">"',
             '"BODY.PEEK[]<0." ++ U32.show(0) ++ ">"',
             "full_fetch_renders_exactly"),
        )
        for old, new, law in render_mutations:
            require(renderer.count(old) == 1, "fetch renderer moved: update mutation explicitly")
            imap.write_text(renderer.replace(old, new), encoding="utf-8")
            rejected = run(root, "PROOF.bend")
            require(rejected.returncode != 0 and law in rejected.stdout + rejected.stderr,
                    (law, rejected.stdout, rejected.stderr))
            print(f"PASS actual Bend fetch-renderer mutation rejected: {law}")
        imap.write_text(renderer, encoding="utf-8")
        restored = run(root, "PROOF.bend")
        require(restored.returncode == 0 and "ALL PROOFS CHECK" in restored.stdout,
                ("restored source failed", restored.stdout, restored.stderr))
        print("PASS restored production contracts: ALL PROOFS CHECK")
    print("PASS actual Bend boundary mutation rejected: maximum boundary UID repeated")


if __name__ == "__main__":
    main()
