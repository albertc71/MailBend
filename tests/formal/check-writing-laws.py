#!/usr/bin/env python3
"""Compile the guide's Bend fences and reject a broken production search plan."""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PATTERNS = {
    "computation": "search_writes_nothing",
    "computed-condition": "get_new_writes_nothing",
    "list-induction": "thread_search_writes_nothing",
    "contradiction": "true_is_not_false",
}


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def snippets(path):
    blocks = {}
    active = None
    lines = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if re.match(r"^\s*(?:`{3,}|~{3,})\s*bend\b", line):
            require(active is None, f"{path}:{number}: nested Bend fence")
            marker = re.fullmatch(r"```bend guide:([a-z-]+)", line)
            require(marker is not None, f"{path}:{number}: unmarked Bend fence")
            active = marker[1]
            require(active in PATTERNS, f"{path}:{number}: unknown snippet {active}")
            require(active not in blocks, f"{path}:{number}: repeated snippet {active}")
            lines = []
        elif active is not None:
            if re.fullmatch(r"\s*(?:`{3,}|~{3,})\s*", line):
                require(line == "```", f"{path}:{number}: use an exact closing ``` fence")
                source = "\n".join(lines) + "\n"
                name = PATTERNS[active]
                require(re.search(rf"^def {re.escape(name)}\(", source, re.M),
                        f"{path}:{number}: {active} lacks proof {name}")
                blocks[active] = source
                active = None
            else:
                require(not re.match(r"^\s*(?:`{3,}|~{3,})", line),
                        f"{path}:{number}: code fence inside unclosed Bend block")
                lines.append(line)
    require(active is None, f"{path}: unclosed Bend fence")
    require(list(blocks) == list(PATTERNS),
            f"{path}: expected snippets in order {list(PATTERNS)}, got {list(blocks)}")
    return "\n".join(blocks.values())


def check(root, verdict=False):
    option = "--verdict" if verdict else "--check-only"
    return subprocess.run(
        ["bend", "Guide.bend", option], cwd=root, capture_output=True, text=True,
        env=dict(os.environ, BEND_NO_TELEMETRY="1"), timeout=300,
    )


def declarations(source, label, strict=False):
    lines = source.splitlines()
    result = {}
    index = 0
    while index < len(lines):
        line = lines[index]
        match = re.match(r"^(law|def) ([A-Za-z_][A-Za-z_0-9.]*)[(:]", line)
        if match is None:
            require(not strict or not line.strip() or line.startswith(("#", "import ")),
                    f"{label}:{index + 1}: unsupported top-level snippet text")
            index += 1
            continue
        end = index + 1
        while end < len(lines) and (not lines[end].strip() or lines[end][0].isspace()):
            end += 1
        key = (match[1], match[2])
        require(key not in result, f"{label}: duplicate {key[0]} {key[1]}")
        result[key] = "\n".join(lines[index:end]).strip()
        index = end
    return result


def require_source_match(source, laws, proofs):
    actual_laws = declarations(laws, "LAWS.bend")
    actual_proofs = declarations(proofs, "PROOF.bend")
    examples = declarations(source, "guide", strict=True)
    require(examples, "guide: no declarations to compare")
    for (kind, name), text in examples.items():
        actual = actual_laws if kind == "law" else actual_proofs
        target = name
        if kind == "def" and ("law", name) in actual_laws:
            target = "Laws." + name
            text = text.replace("def " + name + "(", "def " + target + "(", 1)
        key = (kind, target)
        require(key in actual, f"guide {kind} {name}: missing source declaration {target}")
        require([line.rstrip() for line in text.splitlines()] ==
                [line.rstrip() for line in actual[key].splitlines()],
                f"guide {kind} {name}: differs from source declaration {target}")


def require_pass(result, label):
    require(result.returncode == 0 and "ALL PROOFS CHECK" in result.stdout,
            f"{label}\n{result.stdout}\n{result.stderr}")
    print(f"PASS {label}: ALL PROOFS CHECK")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guide", type=Path, default=ROOT / "docs/WRITING-LAWS.md")
    args = parser.parse_args()
    source = snippets(args.guide)
    require_source_match(source, (ROOT / "LAWS.bend").read_text(encoding="utf-8"),
                         (ROOT / "PROOF.bend").read_text(encoding="utf-8"))
    print("PASS guide declarations match LAWS.bend and PROOF.bend")
    with tempfile.TemporaryDirectory(prefix="mailbend-law-guide-") as directory:
        root = Path(directory)
        shutil.copytree(ROOT / "src", root / "src")
        (root / "Guide.bend").write_text(source, encoding="utf-8")
        require_pass(check(root, verdict=True), "guide snippets, including kernel recheck")

        ops = root / "src/ops.bend"
        original = ops.read_text(encoding="utf-8")
        plan = "  [I.CExamine{mbox}, I.CSearch{keys}]"
        require(original.count(plan) == 1, "search plan moved: update this mutation explicitly")
        ops.write_text(original.replace(plan, plan.replace("CExamine", "CSelect")),
                       encoding="utf-8")
        result = check(root)
        output = result.stdout + result.stderr
        locations = re.findall(r"^Location: (\S+)", output, re.M)
        require(result.returncode != 0 and "SOME PROOFS FAIL" in output
                and locations == ["search_writes_nothing"]
                and re.search(r"^- expected\s*:\s*True\{\}\s*$", output, re.M)
                and re.search(r"^- observed\s*:\s*False\{\}\s*$", output, re.M),
                f"mutant did not fail the intended Boolean equality\n{output}")
        print("PASS rejected SELECT mutant at search_writes_nothing: True is not False")

        ops.write_text(original, encoding="utf-8")
        require_pass(check(root), "restored guide snippets")


if __name__ == "__main__":
    main()
