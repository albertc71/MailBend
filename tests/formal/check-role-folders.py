#!/usr/bin/env python3
"""Check the role-folder proofs, and require Bend to reject broken resolution.

Copies src/ and tests/formal/role-folders.bend into a temporary directory and
breaks Tools.resolved_role's helpers in src/tools.bend there, one mutation at
a time; the checkout is never modified. Each mutant must fail the check at
the example of the law it violates, which comes before the proofs, so the
failure names the folder the broken code would pick. The checkout must check
before and after. `bend PROOF.bend --verdict`, which imports the proofs,
rechecks them with the proven kernel.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PROOFS = "tests/formal/role-folders.bend"

# (name, original text in src/tools.bend, broken text, example that must fail)
MUTATIONS = [
    ("override-ignored",
     "resolved_role.if(String.is_empty(override), fs, override, attr, a, b)",
     "resolved_role.if(True{}, fs, override, attr, a, b)",
     "override_example"),
    ("ambiguous-picks-first",
     "    case I.Folder{name, d, attrs} <> Nil{}:\n"
     "      Bool.pick(Maybe<&2, String>, selectable(attrs), Some{name}, None{})\n"
     "    case _:\n"
     "      None{}",
     "    case I.Folder{name, d, attrs} <> rest:\n"
     "      Bool.pick(Maybe<&2, String>, selectable(attrs), Some{name}, None{})\n"
     "    case Nil{}:\n"
     "      None{}",
     "two_advertised_example"),
    ("names-before-roles",
     "role_fallback(role_candidates(fs, attr, a, b, True{}), fs, attr, a, b)",
     "role_fallback(role_candidates(fs, attr, a, b, False{}), fs, attr, a, b)",
     "sole_advertised_example"),
    ("unselectable-falls-back",
     "    case True{}:\n      I.has_attr(attrs, attr)\n",
     "    case True{}:\n      I.has_attr(attrs, attr) && selectable(attrs)\n",
     "unselectable_advertised_example"),
    ("unselectable-chosen",
     "Bool.pick(Maybe<&2, String>, selectable(attrs), Some{name}, None{})",
     "Some{name}",
     "unselectable_advertised_example"),
    ("conventional-picks-first",
     "unique_folder(role_candidates(fs, attr, a, b, False{}))",
     "unique_folder(List.take(&2, I.Folder, role_candidates(fs, attr, a, b, False{}), 1n))",
     "two_conventional_example"),
    ("other-role-taken-by-name",
     "selectable(attrs) &&\n        Bool.not(recognized_role(attrs))",
     "selectable(attrs)",
     "other_role_example"),
    ("trash-by-junk-attribute",
     'resolved_role(fs, trash, "\\\\Trash", trash_name(), deleted_messages_name())',
     'resolved_role(fs, trash, "\\\\Junk", trash_name(), deleted_messages_name())',
     "each_role_example"),
]


def check(root):
    env = dict(os.environ, BEND_NO_TELEMETRY="1")
    return subprocess.run(["bend", PROOFS, "--check-only"], cwd=root,
                          capture_output=True, text=True, env=env, timeout=300)


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def require_checks(root, label):
    result = check(root)
    require(result.returncode == 0 and "ALL PROOFS CHECK" in result.stdout,
            (label, result.stdout, result.stderr))
    print(f"PASS {label}: ALL PROOFS CHECK")


# A failed {==} prints the broken code's value as `expected` and the law's
# claim as `observed`.
def value(output, side):
    return next((line.split(":", 1)[1].strip() for line in output.splitlines()
                 if line.startswith(f"- {side}")), "?")


def main():
    require_checks(ROOT, "role-folder proofs")
    source = (ROOT / "src/tools.bend").read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="mailbend-role-mutation-") as scratch:
        shutil.copytree(ROOT / "src", Path(scratch, "src"))
        Path(scratch, "tests/formal").mkdir(parents=True)
        shutil.copy2(ROOT / PROOFS, Path(scratch, PROOFS))
        tools = Path(scratch, "src/tools.bend")
        for name, original, broken, example in MUTATIONS:
            require(source.count(original) == 1, (name, "mutation target not found once"))
            tools.write_text(source.replace(original, broken), encoding="utf-8")
            result = check(scratch)
            output = result.stdout + result.stderr
            require(result.returncode != 0 and "SOME PROOFS FAIL" in output, (name, output))
            require(f"Location: {example}" in output, (name, example, output))
            print(f"PASS rejected {name}: {example} gives {value(output, 'expected')}, "
                  f"not {value(output, 'observed')}")
    require_checks(ROOT, "checkout unchanged")


if __name__ == "__main__":
    main()
