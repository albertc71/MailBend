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
    ("wrong event kind stays quiet", 'case False{}:\n      uncertain()\n\ndef event.kind(',
     'case False{}:\n      Quiet{}\n\ndef event.kind('),
    ("missing event kind stays quiet", 'case None{}:\n      uncertain()\n    case Some{name}:',
     'case None{}:\n      Quiet{}\n    case Some{name}:'),
    ("nonobject tool input stays quiet", 'case _ _:\n      uncertain()\n\ndef event.kind.if(',
     'case Some{_} _:\n      Quiet{}\n    case _ _:\n      uncertain()\n\ndef event.kind.if('),
)

EXPECTED_LAWS = {
    "wrong event kind stays quiet": "hook_wrong_kind_asks",
    "missing event kind stays quiet": "hook_wrong_kind_asks",
    "nonobject tool input stays quiet": "hook_nonobject_input_asks",
}

# Explicitly inhabit each premise, with a known read tool that would be quiet
# for valid PreToolUse/object input. These also prevent vacuous law changes.
WITNESSES = """
def wrong_kind_witness() -> Laws.hook_wrong_kind(Some{"PostToolUse"}):
  {==}

def missing_kind_witness() -> Laws.hook_wrong_kind(None{}):
  Unit{}

def nonobject_input_witness() -> Laws.hook_nonobject_input(Some{J.JArr{J.JEnd{}}}):
  Unit{}

def missing_input_witness() -> Laws.hook_nonobject_input(None{}):
  Unit{}

def wrong_kind_printed_ask()
  -> {Laws.hook_printed_decision(Hook.event.kind(Some{"PostToolUse"},
    J.obj([J.kv("tool_name", J.str("mail_get")), J.kv("tool_input", J.obj([]))]))) ==
      Some{"ask"} : Maybe<&2, String>}:
  Laws.hook_wrong_kind_asks(Some{"PostToolUse"},
    J.obj([J.kv("tool_name", J.str("mail_get")), J.kv("tool_input", J.obj([]))]),
    wrong_kind_witness())

def nonobject_input_printed_ask()
  -> {Laws.hook_printed_decision(Hook.event.fields(Some{"mail_get"},
    Some{J.JArr{J.JEnd{}}})) == Some{"ask"} : Maybe<&2, String>}:
  Laws.hook_nonobject_input_asks("mail_get", Some{J.JArr{J.JEnd{}}}, nonobject_input_witness())
"""


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
            IMPORTS + "import ./LAWS.bend as Laws\n" + proofs.split(SECTION)[1] + WITNESSES)
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
            if name in EXPECTED_LAWS:
                assert f"Location: Laws.{EXPECTED_LAWS[name]}" in output, (name, output)
            for syntax_error in ("Error parsing", "consumed more than once", "a defined name"):
                assert syntax_error not in output, (name, output)
            print(f"PASS rejected {name}")
            (root / "src/hook.bend").write_text(original)
        result = check(root)
        assert result.returncode == 0 and "ALL PROOFS CHECK" in result.stdout, result
        print("PASS restored hook laws")


if __name__ == "__main__":
    main()
