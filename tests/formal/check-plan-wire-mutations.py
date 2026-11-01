#!/usr/bin/env python3
"""Require the universal plan and wire laws to reject broken production code.

Each mutation changes one source module in a temporary copy. Rejection must
name the expected universal proof, not a parser error or an unrelated failure.
The checkout and the restored copy must both pass before this check succeeds.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
GUARD = '[I.CSelect{mbox}, I.CExpect{I.uidv_line(uidv)}, I.CSearch{[I.KUids{uids}]}]'
MUTATIONS = (
    ("guard selects another folder", "src/ops.bend", GUARD,
     GUARD.replace('CSelect{mbox}', 'CSelect{"Other"}'), "mark_opens_callers_folder"),
    ("guard searches other UIDs", "src/ops.bend", GUARD,
     GUARD.replace('KUids{uids}', 'KUids{[99]}'), "mark_opens_callers_folder"),
    ("folder switches after guard", "src/ops.bend", GUARD,
     GUARD[:-1] + ', I.CSelect{"Other"}]', "mark_opens_callers_folder"),
    ("STORE loses UID prefix", "src/imap.bend", '"UID STORE " ++ uid_set(us)',
     '"STORE " ++ uid_set(us)', "store_renders_exactly"),
    ("Seen becomes Deleted", "src/imap.bend", 'case FSeen{}:\n      "\\\\Seen"',
     'case FSeen{}:\n      "\\\\Deleted"', "store_renders_exactly"),
    ("STORE operations swap", "src/imap.bend",
     'Bool.pick(String, add, "+FLAGS.SILENT (", "-FLAGS.SILENT (")',
     'Bool.pick(String, add, "-FLAGS.SILENT (", "+FLAGS.SILENT (")',
     "store_renders_exactly"),
    ("UID list gains a range", "src/imap.bend", 'U32.show(u) ++ "," ++ uid_set(t)',
     'U32.show(u) ++ ":" ++ uid_set(t)', "uid_set_is_comma_joined"),
    ("SELECT renders another folder", "src/imap.bend", '"SELECT " ++ mailbox(m)',
     '"SELECT " ++ mailbox("Other")', "select_renders_callers_folder"),
    ("UID search renders other UIDs", "src/imap.bend",
     'case KUids{us}:\n      "UID " ++ uid_set(us)',
     'case KUids{us}:\n      "UID 99"', "guard_search_renders_exact_uids"),
    ("tool lookup returns no operation", "src/ops.bend", '  find_op(all_ops(), n)',
     '  None{}', "from_name_inverts_name"),
)


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def check(root):
    return subprocess.run(
        ["bend", "PROOF.bend"], cwd=root, capture_output=True, text=True,
        env=dict(os.environ, BEND_NO_TELEMETRY="1"), timeout=300)


def require_checks(root, label):
    result = check(root)
    require(result.returncode == 0 and "ALL PROOFS CHECK" in result.stdout,
            (label, result.stdout, result.stderr))
    print(f"PASS {label}: ALL PROOFS CHECK", flush=True)


def main():
    require_checks(ROOT, "checkout")
    sources = {path: (ROOT / path).read_text(encoding="utf-8")
               for _, path, _, _, _ in MUTATIONS}
    with tempfile.TemporaryDirectory(prefix="mailbend-plan-wire-mutation-") as directory:
        root = Path(directory)
        shutil.copytree(ROOT / "src", root / "src")
        shutil.copytree(ROOT / "tests/formal", root / "tests/formal",
                        ignore=shutil.ignore_patterns("__pycache__", "mailbend-*-mutation-*"))
        for name in ("LAWS.bend", "PROOF.bend"):
            shutil.copy2(ROOT / name, root / name)
        require_checks(root, "copied checkout")
        for name, path, original, broken, law in MUTATIONS:
            source = sources[path]
            require(source.count(original) == 1, (name, "mutation target not found once"))
            target = root / path
            target.write_text(source.replace(original, broken), encoding="utf-8")
            result = check(root)
            output = result.stdout + result.stderr
            location = re.search(r"^Location: (\S+)", output, re.MULTILINE)
            require(result.returncode != 0 and "SOME PROOFS FAIL" in output
                    and location is not None and location.group(1) in (law, f"Laws.{law}")
                    and re.search(r"^- expected\s*:", output, re.MULTILINE)
                    and re.search(r"^- observed\s*:", output, re.MULTILINE),
                    (name, law, result.returncode, output))
            print(f"PASS rejected {name}: {location.group(1)}", flush=True)
            target.write_text(source, encoding="utf-8")
        require_checks(root, "restored copy")
    for path, source in sources.items():
        require((ROOT / path).read_text(encoding="utf-8") == source,
                (path, "checkout changed during mutation checks"))
    print("PASS checkout unchanged", flush=True)


if __name__ == "__main__":
    main()
