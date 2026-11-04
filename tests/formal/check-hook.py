#!/usr/bin/env python3
"""Check the hook laws alone, then require production mutants to break them."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SECTION = "# Client-side prompts\n# -------------------\n"
IMPORTS = ("import Base\nimport ./src/hook.bend as Hook\n"
           "import ./src/codec.bend as C\n"
           "import ./src/json.bend as J\nimport ./src/ops.bend as Ops\n"
           "import ./src/policy.bend as Policy\n")
MUTATIONS = (
    ("allow decision", 'J.str("ask")', 'J.str("allow")'),
    ("real changes stay quiet", 'Ask{reason}\n    case _ _:', 'Quiet{}\n    case _ _:'),
    ("deletes omit the prompt", 'Policy.sends(op, args) || Ops.is_destructive(op)',
     'Policy.sends(op, args)'),
    ("printed output diverges", 'J.show(response(d))', '"allow"'),
    ("uncertain input stays quiet", 'Ask{"MailBend could not inspect this tool call. '
     'Check its arguments before continuing."}', 'Quiet{}'),
    ("unknown tool stays quiet", 'case None{}:\n      uncertain()\n    case Some{o}:',
     'case None{}:\n      Quiet{}\n    case Some{o}:'),
    ("oversized input stays quiet", 'case True{}:\n      uncertain()\n    case False{}:',
     'case True{}:\n      Quiet{}\n    case False{}:'),
)


def check(root):
    return subprocess.run(["bend", "PROOF.bend", "--check-only"], cwd=root,
                          env=dict(os.environ, BEND_NO_TELEMETRY="1"), capture_output=True,
                          text=True, timeout=120)


def main():
    laws = (ROOT / "LAWS.bend").read_text()
    proofs = (ROOT / "PROOF.bend").read_text()
    assert laws.count(SECTION) == proofs.count(SECTION) == 1
    with tempfile.TemporaryDirectory(prefix="mailbend-hook-proofs-") as directory:
        root = Path(directory)
        shutil.copytree(ROOT / "src", root / "src")
        (root / "LAWS.bend").write_text(IMPORTS + laws.split(SECTION)[1])
        (root / "PROOF.bend").write_text(
            IMPORTS + "import ./LAWS.bend as Laws\n" + proofs.split(SECTION)[1])
        original = (root / "src/hook.bend").read_text()
        result = check(root)
        assert result.returncode == 0 and "ALL PROOFS CHECK" in result.stdout, result
        print("PASS isolated hook laws")
        for name, before, after in MUTATIONS:
            assert original.count(before) == 1, name
            (root / "src/hook.bend").write_text(original.replace(before, after))
            result = check(root)
            output = result.stdout + result.stderr
            assert result.returncode != 0 and "SOME PROOFS FAIL" in output, (name, output)
            assert "expected" in output and "observed" in output, (name, output)
            for syntax_error in ("Error parsing", "consumed more than once", "a defined name"):
                assert syntax_error not in output, (name, output)
            print(f"PASS rejected {name}")
            (root / "src/hook.bend").write_text(original)
        result = check(root)
        assert result.returncode == 0 and "ALL PROOFS CHECK" in result.stdout, result
        print("PASS restored hook laws")


if __name__ == "__main__":
    main()
