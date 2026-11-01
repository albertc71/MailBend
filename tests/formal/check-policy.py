#!/usr/bin/env python3
"""Require universal policy laws to reject broken production code.

The isolated entry contains the real policy laws and their proofs, without
examples or unrelated older laws that could mask the intended rejection.
The full checkout still checks before and after. All mutations use copies.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SECTION = "# Policy and classifier soundness\n# -------------------------------\n"
END_SECTION = "# End policy and classifier soundness\n"
MUTATIONS = [
    ("STORE is non-writing", "src/imap.bend", "case CStore{u, a, f}:\n      EMail{}",
     "case CStore{u, a, f}:\n      ENone{}", "store_classifies_as_writing"),
    ("COPY is non-writing", "src/imap.bend", "case CCopy{u, d}:\n      ECopy{}",
     "case CCopy{u, d}:\n      ENone{}", "copy_classifies_as_writing"),
    ("MOVE is non-writing", "src/imap.bend", "case CMove{u, d}:\n      EMail{}",
     "case CMove{u, d}:\n      ENone{}", "move_classifies_as_writing"),
    ("EXPUNGE is non-writing", "src/imap.bend", "case CExpunge{u}:\n      EExpunge{}",
     "case CExpunge{u}:\n      ENone{}", "expunge_classifies_as_writing"),
    ("APPEND is non-writing", "src/imap.bend", "case CAppend{m, f, b}:\n      EMail{}",
     "case CAppend{m, f, b}:\n      ENone{}", "append_classifies_as_writing"),
    ("CREATE is non-writing", "src/imap.bend", "case CCreate{m}:\n      EFolder{}",
     "case CCreate{m}:\n      ENone{}", "create_classifies_as_writing"),
    ("RENAME is non-writing", "src/imap.bend", "case CRename{a, b}:\n      EFolder{}",
     "case CRename{a, b}:\n      ENone{}", "rename_classifies_as_writing"),
    ("SUBSCRIBE is non-writing", "src/imap.bend", "case CSubscribe{m}:\n      EFolder{}",
     "case CSubscribe{m}:\n      ENone{}", "subscribe_classifies_as_writing"),
    ("UNSUBSCRIBE is non-writing", "src/imap.bend", "case CUnsubscribe{m}:\n      EFolder{}",
     "case CUnsubscribe{m}:\n      ENone{}", "unsubscribe_classifies_as_writing"),
    ("SELECT is non-writing", "src/imap.bend", "case CSelect{m}:\n      ESelect{}",
     "case CSelect{m}:\n      ENone{}", "select_classifies_as_writing"),
    ("writing effect reports no write", "src/imap.bend",
     "case ESelect{}:\n      True{}\n    case EMail{}:\n      True{}",
     "case ESelect{}:\n      True{}\n    case EMail{}:\n      False{}",
     "store_classifies_as_writing"),
    ("plan classifier ignores later commands", "src/imap.bend",
     "writes(effect(c)) || any_writes(t)", "writes(effect(c))",
     "any_writes_checks_each_command"),
    ("draft loses Draft flag", "src/ops.bend", "[I.CAppend{drafts, [I.FDraft{}, I.FSeen{}], msg}]",
     "[I.CAppend{drafts, [I.FSeen{}], msg}]", "draft_is_exact_append"),
    ("draft adds a command", "src/ops.bend", "[I.CAppend{drafts, [I.FDraft{}, I.FSeen{}], msg}]",
     "[I.CCapability{}, I.CAppend{drafts, [I.FDraft{}, I.FSeen{}], msg}]",
     "draft_is_exact_append"),
    ("refused helper counts as lost", "src/policy.bend",
     "case ProcRefused{m}:\n      False{}", "case ProcRefused{m}:\n      True{}",
     "refused_helper_is_not_lost"),
    ("send classifier misses SMTP", "src/policy.bend", "case Ops.OSend{}:\n      True{}",
     "case Ops.OSend{}:\n      False{}", "sending_calls_are_exact"),
    ("read-only gate disabled", "src/policy.bend", "ro && Bool.not(Ops.is_read_only(op))",
     "False{}", "read_only_refuses_writes"),
    ("drafts-only gate disabled", "src/policy.bend", "drafts && sends(op, args)",
     "False{}", "drafts_only_refuses_sends"),
    ("Jev-off gate disabled", "src/policy.bend", "Bool.not(jev) && Ops.needs_jev(op)",
     "False{}", "jev_off_refuses_jev_calls"),
    ("malformed switch reads as off", "src/policy.bend",
     'FlagBad{name ++ " must be 1, true, 0, false or empty"}', "FlagOff{}",
     "malformed_switch_is_bad"),
    ("bad flag is accepted", "src/policy.bend", "case FlagBad{m}:\n      Fail{m}",
     "case FlagBad{m}:\n      Done{False{}}", "bad_read_only_rejects_config"),
    ("role invents an unlisted name", "src/policy.bend",
     "Bool.pick(Maybe<&2, String>, selectable(attrs), Some{name}, None{})",
     'Bool.pick(Maybe<&2, String>, selectable(attrs), Some{"Unlisted"}, None{})',
     "unique_membership"),
]


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def check(root):
    return subprocess.run(["bend", "PROOF.bend", "--check-only"], cwd=root,
                          capture_output=True, text=True, timeout=120,
                          env=dict(os.environ, BEND_NO_TELEMETRY="1"))


def require_checks(root, label):
    result = check(root)
    require(result.returncode == 0 and "ALL PROOFS CHECK" in result.stdout,
            (label, result.stdout, result.stderr))
    print(f"PASS {label}: ALL PROOFS CHECK", flush=True)


def import_boundary(root=ROOT):
    pending = [root / "PROOF.bend"]
    visited = set()
    forbidden = {root / name for name in
                 ("src/tools.bend", "src/schema.bend", "src/diagnostics.bend", "main.bend")}
    while pending:
        path = pending.pop().resolve()
        if path in visited:
            continue
        require(path not in forbidden, ("policy proof imports tool orchestration", path))
        visited.add(path)
        source = path.read_text(encoding="utf-8")
        for relative in re.findall(r"^\s*import\s+(\.[\w./-]+\.bend)\s+as\s+\w+\s*(?:#.*)?$",
                                   source, re.M):
            pending.append(path.parent / relative)
    source = (root / "src/policy.bend").read_text(encoding="utf-8")
    code = re.sub(r'"(?:\\.|[^"\\])*"|#[^\n]*', "", source)
    require(not re.search(r"\b(?:IO|Process)\b", code), "policy contains direct IO")
    print("PASS proof imports exclude tool orchestration and schema; policy has no direct IO",
          flush=True)


def main():
    import_boundary()
    require_checks(ROOT, "checkout")
    sources = {path: (ROOT / path).read_text(encoding="utf-8")
               for _, path, _, _, _ in MUTATIONS}
    laws = (ROOT / "LAWS.bend").read_text(encoding="utf-8")
    proofs = (ROOT / "PROOF.bend").read_text(encoding="utf-8")
    require(laws.count(SECTION) == proofs.count(SECTION) == 1, "policy section must be unique")
    imports = ("import Base\nimport ./src/json.bend as J\nimport ./src/imap.bend as I\n"
               "import ./src/ops.bend as Ops\nimport ./src/policy.bend as Policy\n"
               "import ./src/jev.bend as Jev\n")
    require(laws.count(END_SECTION) == proofs.count(END_SECTION) == 1,
            "policy section end must be unique")
    policy_laws = laws.split(SECTION)[1].split(END_SECTION)[0]
    policy_proofs = proofs.split(SECTION)[1].split(END_SECTION)[0]
    with tempfile.TemporaryDirectory(prefix="mailbend-policy-mutation-") as directory:
        root = Path(directory)
        shutil.copytree(ROOT / "src", root / "src")
        (root / "LAWS.bend").write_text(imports + policy_laws, encoding="utf-8")
        (root / "PROOF.bend").write_text(
            imports + "import ./LAWS.bend as Laws\n" + policy_proofs,
            encoding="utf-8")
        proof_entry = root / "PROOF.bend"
        original_entry = proof_entry.read_text(encoding="utf-8")
        proof_entry.write_text(original_entry +
                               "\n import  ./src/tools.bend  as Forbidden  # trailing comment\n",
                               encoding="utf-8")
        try:
            import_boundary(root)
        except AssertionError as error:
            require("policy proof imports tool orchestration" in str(error), error)
        else:
            raise AssertionError("import boundary accepted a commented tools import")
        proof_entry.write_text(original_entry, encoding="utf-8")
        policy = root / "src/policy.bend"
        original_policy = policy.read_text(encoding="utf-8")
        policy.write_text(original_policy + "\ndef forbidden() -> IO(Unit):\n  return Unit{}\n",
                          encoding="utf-8")
        try:
            import_boundary(root)
        except AssertionError as error:
            require("policy contains direct IO" in str(error), error)
        else:
            raise AssertionError("policy boundary accepted an IO result type")
        policy.write_text(original_policy, encoding="utf-8")
        print("PASS boundary checks reject commented tools imports and direct IO types", flush=True)
        require_checks(root, "isolated universal laws without examples")
        for name, path, original, broken, law in MUTATIONS:
            source = sources[path]
            require(source.count(original) == 1, (name, "mutation target not found once"))
            wanted = "resolved_role_names_selectable_folder" if law == "unique_membership" else law
            law_entry = re.sub(
                r"^law (\w+):.*?(?=^def |^law |^#|\Z)",
                lambda match: match.group() if match.group(1) == wanted else "",
                policy_laws, flags=re.M | re.S)
            proof_entry_text = re.sub(
                r"^def Laws\.(\w+)\(.*?(?=^def |^#|\Z)",
                lambda match: match.group() if match.group(1) == wanted else "",
                policy_proofs, flags=re.M | re.S)
            (root / "LAWS.bend").write_text(imports + law_entry, encoding="utf-8")
            (root / "PROOF.bend").write_text(
                imports + "import ./LAWS.bend as Laws\n" + proof_entry_text, encoding="utf-8")
            require_checks(root, f"isolated {wanted}")
            target = root / path
            target.write_text(source.replace(original, broken), encoding="utf-8")
            result = check(root)
            output = result.stdout + result.stderr
            location = re.search(r"^Location: (\S+)", output, re.M)
            require(result.returncode != 0 and "SOME PROOFS FAIL" in output
                    and location is not None and location.group(1) in (law, f"Laws.{law}")
                    and re.search(r"^- expected\s*:", output, re.M)
                    and re.search(r"^- observed\s*:", output, re.M)
                    and not re.search(r"consumed more than once|a defined name|a term \(|"
                                      r"a live scrutinee|can.t be matched|Error parsing", output),
                    (name, law, result.returncode, output))
            print(f"PASS rejected {name}: {location.group(1)}", flush=True)
            target.write_text(source, encoding="utf-8")
        (root / "LAWS.bend").write_text(imports + policy_laws, encoding="utf-8")
        (root / "PROOF.bend").write_text(original_entry, encoding="utf-8")
        require_checks(root, "restored copy")
    for path, source in sources.items():
        require((ROOT / path).read_text(encoding="utf-8") == source, (path, "checkout changed"))
    require_checks(ROOT, "checkout unchanged")


if __name__ == "__main__":
    main()
