#!/usr/bin/env python3
"""Check the role-folder proofs, and require Bend to reject broken resolution.

Copies src/ and tests/formal/role-folders.bend into a temporary directory and
breaks Tools.resolved_role's helpers in src/tools.bend there, one mutation at
a time; the checkout is never modified. Each mutant must fail the check twice:
at the example of the law it violates, which comes before the proofs, so the
failure names the folder the broken code would pick; and, with the examples
removed, inside the proofs, so the universal laws reject it on their own. The
checkout must check before and after. `bend PROOF.bend --verdict`, which
imports the proofs, rechecks them with the proven kernel.
"""
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PROOFS = "tests/formal/role-folders.bend"
EXAMPLES = "# Examples\n# --------\n"
PROOFS_SECTION = "# Proofs\n# ======\n"

# (name, original text in src/tools.bend, broken text, example that must fail)
MUTATIONS = [
    ("override-ignored",
     "resolved_role.if(String.is_empty(override), fs, override, attr, a, b)",
     "resolved_role.if(True{}, fs, override, attr, a, b)",
     "override_example"),
    ("override-matches-fixed-name",
     "  unique_folder(override_candidates(fs, name))",
     '  unique_folder(override_candidates(fs, "Trash"))',
     "override_example"),
    ("unlisted-override-trusted",
     "def named_folder(fs: List<&2, I.Folder>, name: String) -> Maybe<&2, String>:\n"
     "  unique_folder(override_candidates(fs, name))",
     "def named_folder(fs: List<&2, I.Folder>, +name: String) -> Maybe<&2, String>:\n"
     "  Maybe.or(&2, String, unique_folder(override_candidates(fs, name)), Some{name})",
     "unlisted_override_example"),
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
    ("nonexistent-ignored",
     'Bool.not(I.has_attr(attrs, "\\\\Noselect") || I.has_attr(attrs, "\\\\NonExistent"))',
     'Bool.not(I.has_attr(attrs, "\\\\Noselect"))',
     "nonexistent_advertised_example"),
    ("conventional-picks-first",
     "unique_folder(role_candidates(fs, attr, a, b, False{}))",
     "unique_folder(List.take(&2, I.Folder, role_candidates(fs, attr, a, b, False{}), 1n))",
     "two_conventional_example"),
    ("other-role-taken-by-name",
     "selectable(attrs) &&\n        Bool.not(recognized_role(attrs))",
     "selectable(attrs)",
     "other_role_example"),
    ("all-mail-not-a-role",
     '    RoleAttr{"\\\\All", "all"},\n',
     "",
     "all_mail_folder_example"),
    ("important-not-a-role",
     ',\n    RoleAttr{"\\\\Important", "important"}',
     "",
     "important_folder_example"),
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


def location(output):
    found = re.search(r"^Location: (\S+)", output, re.M)
    return found.group(1) if found else "?"


def rejected(root, name):
    result = check(root)
    output = result.stdout + result.stderr
    require(result.returncode != 0 and "SOME PROOFS FAIL" in output, (name, output))
    return output


def main():
    require_checks(ROOT, "role-folder proofs")
    source = (ROOT / "src/tools.bend").read_text(encoding="utf-8")
    proofs = (ROOT / PROOFS).read_text(encoding="utf-8")
    laws_only = proofs[:proofs.index(EXAMPLES)] + proofs[proofs.index(PROOFS_SECTION):]
    proof_defs = set(re.findall(r"^def ([\w.]+)", laws_only[laws_only.index(PROOFS_SECTION):],
                                re.M))
    with tempfile.TemporaryDirectory(prefix="mailbend-role-mutation-") as scratch:
        shutil.copytree(ROOT / "src", Path(scratch, "src"))
        Path(scratch, "tests/formal").mkdir(parents=True)
        target = Path(scratch, PROOFS)
        tools = Path(scratch, "src/tools.bend")
        target.write_text(laws_only, encoding="utf-8")
        require_checks(scratch, "role-folder proofs without the examples")
        for name, original, broken, example in MUTATIONS:
            require(source.count(original) == 1, (name, "mutation target not found once"))
            tools.write_text(source.replace(original, broken), encoding="utf-8")
            target.write_text(proofs, encoding="utf-8")
            output = rejected(scratch, name)
            require(location(output) == example, (name, example, output))
            target.write_text(laws_only, encoding="utf-8")
            failed = location(rejected(scratch, name))
            require(failed in proof_defs, (name, "no proof rejected it", failed))
            print(f"PASS rejected {name}: {example} gives {value(output, 'expected')}, "
                  f"not {value(output, 'observed')}; without the examples, {failed} fails")
    require_checks(ROOT, "checkout unchanged")


if __name__ == "__main__":
    main()
