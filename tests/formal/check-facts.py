#!/usr/bin/env python3
"""Reject five facts regressions with the exact focused laws from the root contract.

The full root verdict supplies kernel rechecking. These isolated negative controls
check provider-specific span widths, rendered values, and inhabited extractions.
"""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
NAMES = ("meeting_facts_spans_within_text", "meeting_facts_emitted_values",
         "meeting_facts_complete_source_witness", "meeting_facts_unicode_source_witness",
         "meeting_facts_zoom_complete_source_witness", "meeting_facts_zoom_unicode_source_witness")
FILES = ("src/facts.bend", "LAWS.bend", "PROOF.bend",
         "tests/formal/facts-observers.bend", "tests/formal/facts-proofs.bend")
IMPORTS = ("import Base\nimport ./src/facts.bend as Facts\nimport ./src/json.bend as J\n"
           "import ./tests/formal/facts-observers.bend as FactObserve\n")
MUTATIONS = (
    ("emitted-span-width",
     "Span{offset, Nat.add(offset, 36n), line}",
     "Span{offset, Nat.add(offset, 35n), line}", "scan_bounds", None),
    ("emitted-zoom-span-width",
     "ZoomSpan{offset, Nat.add(offset, zoom), line}",
     "ZoomSpan{offset, Nat.add(offset, 513n), line}", "scan_bounds", None),
    ("rendered-value",
     'J.kv("value", J.str(String.take(String.drop(source, start), Nat.sub(end, start))))',
     'J.kv("value", J.str("changed"))', "rendered_all", None),
    ("always-empty",
     "scan(65536n, source, 16n, ending, True{}, 0n, 1n, [])",
     "Extraction{[], False{}}", "meeting_facts_complete_source_witness",
     ("meeting_facts_complete_source_witness",)),
    ("zoom-disabled",
     "      zoom_candidate_within(source, fuel, ending)\n",
     "      0n\n", "meeting_facts_zoom_complete_source_witness",
     ("meeting_facts_zoom_complete_source_witness",)),
)


def declaration(text, prefix):
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.startswith(prefix)]
    assert len(starts) == 1, prefix
    start = starts[0]
    end = start + 1
    while end < len(lines) and (not lines[end].strip() or lines[end][0].isspace()):
        end += 1
    return "".join(lines[start:end]).rstrip() + "\n"


def probe(witnesses=None):
    names = NAMES if witnesses is None else witnesses
    result = IMPORTS
    if witnesses is None:
        result += "import ./tests/formal/facts-proofs.bend as FactProof\n"
    for name in names:
        result += "\n" + declaration((ROOT / "LAWS.bend").read_text(), "law " + name + ":")
        result += "\n" + declaration((ROOT / "PROOF.bend").read_text(), "def Laws." + name + "(").replace(
            "def Laws." + name, "def " + name, 1)
    return result


def run(root):
    return subprocess.run(["bend", "facts-check.bend", "--check-only"], cwd=root,
                          env=dict(os.environ, BEND_NO_TELEMETRY="1"), capture_output=True,
                          text=True, timeout=120)


def hashes():
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in FILES}


def main():
    before = hashes()
    source = (ROOT / "src/facts.bend").read_text()
    with tempfile.TemporaryDirectory(prefix="mailbend-facts-proofs-") as work:
        root = Path(work)
        shutil.copytree(ROOT / "src", root / "src")
        shutil.copytree(ROOT / "tests/formal", root / "tests/formal")
        check = root / "facts-check.bend"
        check.write_text(probe())
        base = run(root)
        assert base.returncode == 0 and "ALL PROOFS CHECK" in base.stdout, base.stdout + base.stderr
        print("PASS focused root facts laws")
        for name, original, broken, expected_location, witnesses in MUTATIONS:
            assert source.count(original) == 1, (name, "mutation target drifted")
            (root / "src/facts.bend").write_text(source.replace(original, broken))
            check.write_text(probe(witnesses))
            result = run(root)
            output = result.stdout + result.stderr
            location = re.search(r"^Location: (\S+)", output, re.M)
            assert result.returncode != 0 and "SOME PROOFS FAIL" in output, (name, output)
            assert location and location.group(1) == expected_location, (name, output)
            assert "- expected" in output and "- observed" in output, (name, output)
            print(f"PASS rejected {name} at {expected_location}")
            print(output.strip())
        (root / "src/facts.bend").write_text(source)
        check.write_text(probe())
        restored = run(root)
        assert restored.returncode == 0 and "ALL PROOFS CHECK" in restored.stdout, restored.stdout + restored.stderr
        print("PASS restored focused root facts laws")
    assert before == hashes(), "checkout changed"
    print("PASS checkout unchanged")


if __name__ == "__main__":
    main()

