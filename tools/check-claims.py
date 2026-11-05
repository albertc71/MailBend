#!/usr/bin/env python3
"""Validate public safety claims and generate their law/test/code coverage."""

import argparse
from pathlib import Path
import re
import sys

from law_catalogue import (ROOT, bend_names, generated, laws, load_json, local_path,
                           observer_names, proof_files, reference, require)

MARKER = re.compile(r"<!-- claim:([a-z][a-z0-9-]*) -->")


def strings(values, label, nonempty=True):
    require(isinstance(values, list) and (values or not nonempty)
            and all(isinstance(v, str) and v for v in values), f"{label}: expected a string list")
    require(len(values) == len(set(values)), f"{label}: duplicate reference")


def readme_lines(source):
    fence = None
    ancestors = []
    anchors = set()
    result = []
    for number, line in enumerate(source.splitlines(), 1):
        delimiter = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if fence is not None:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + "{" + str(fence[1]) + r",}\s*", line):
                fence = None
            continue
        if delimiter:
            fence = (delimiter[1][0], len(delimiter[1]))
            continue
        heading = re.match(r"^(#{1,6}) (.+)$", line)
        if heading:
            slug = re.sub(r"[^\w -]", "", heading[2].lower()).replace(" ", "-")
            anchor = slug
            index = 0
            while anchor in anchors:
                index += 1
                anchor = f"{slug}-{index}"
            anchors.add(anchor)
            level = len(heading[1])
            ancestors = [(depth, name) for depth, name in ancestors if depth < level]
            ancestors.append((level, anchor))
        result.append((number, line, {name for _, name in ancestors}))
    return anchors, result


def validate(root):
    records = laws(root)
    manifest = load_json(local_path(root, "docs/safety-claims.json"))
    require(isinstance(manifest, dict) and set(manifest) == {"version", "claims", "unclaimed"}
            and manifest["version"] == 1, "invalid safety-claims manifest schema")
    require(isinstance(manifest["claims"], list) and manifest["claims"], "claims must be a nonempty list")
    require(isinstance(manifest["unclaimed"], dict), "unclaimed must map law names to reasons")
    readme = local_path(root, "README.md").read_text(encoding="utf-8")
    anchors, visible_lines = readme_lines(readme)
    reachable = proof_files(root)
    source_names = {}
    root_proofs = bend_names(root / "PROOF.bend", "def")
    claims = {}
    claimed = set()
    mutation_ids = set()
    for claim in manifest["claims"]:
        require(isinstance(claim, dict), "claim must be an object")
        fields = {"id", "claim", "anchor", "status", "laws", "tests", "code", "mutation"}
        require(set(claim) <= fields and fields - {"mutation"} <= set(claim),
                f"invalid claim fields: {claim.get('id')}")
        name = claim["id"]
        require(isinstance(name, str) and re.fullmatch(r"[a-z][a-z0-9-]*", name), "invalid claim id")
        require(name not in claims, f"duplicate claim {name}")
        claims[name] = claim
        require(isinstance(claim["claim"], str) and claim["claim"].strip(), f"{name}: missing claim text")
        require(claim["status"] in ("proven", "tested", "reviewed"), f"{name}: invalid status")
        require(claim["anchor"] in anchors, f"{name}: missing README anchor {claim['anchor']}")
        strings(claim["laws"], name + " laws", nonempty=claim["status"] == "proven")
        strings(claim["tests"], name + " tests", nonempty=claim["status"] != "reviewed")
        strings(claim["code"], name + " code")
        for law in claim["laws"]:
            if "#" in law:
                path, _ = reference(root, law, "law", source_names)
                require(local_path(root, path) in reachable, f"{name}: law not imported by PROOF.bend: {law}")
            else:
                require(law in records, f"{name}: missing law {law}")
                require("Laws." + law in root_proofs,
                        f"{name}: missing root proof {law}")
                claimed.add(law)
        for test in claim["tests"]:
            reference(root, test, "test", source_names)
        for code in claim["code"]:
            if "#" in code:
                reference(root, code, "code", source_names)
            else:
                local_path(root, code)
        mutation = claim.get("mutation")
        if claim["status"] == "proven":
            require(isinstance(mutation, dict), f"{name}: proven claim needs a mutation")
            require(set(mutation) == {"id", "path", "before", "after", "proof", "law", "observer_reason"},
                    f"{name}: invalid mutation fields")
            require(re.fullmatch(r"[a-z][a-z0-9-]*", mutation["id"]) is not None
                    and mutation["id"] not in mutation_ids, f"{name}: invalid or duplicate mutation id")
            mutation_ids.add(mutation["id"])
            require(mutation["path"].startswith("src/") and mutation["path"].endswith(".bend"),
                    f"{name}: mutations may target only production Bend modules")
            require(mutation["path"] in {code.split("#", 1)[0] for code in claim["code"]},
                    f"{name}: mutation target is not cited claim code")
            source = local_path(root, mutation["path"]).read_text(encoding="utf-8")
            before, after = mutation["before"], mutation["after"]
            require(isinstance(before, str) and before and isinstance(after, str) and before != after,
                    f"{name}: invalid mutation replacement")
            require(source.count(before) == 1, f"{name}: mutation target must occur exactly once")
            path, proof_name = reference(root, mutation["proof"], "proof", source_names)
            require(mutation["law"] in claim["laws"], f"{name}: mutation rejects an uncited law")
            require(isinstance(mutation["observer_reason"], str) and mutation["observer_reason"].strip(),
                    f"{name}: mutation observer needs a relationship explanation")
            if path == "PROOF.bend" and proof_name.startswith("Laws."):
                require(proof_name[5:] == mutation["law"], f"{name}: mutation observer and law disagree")
            observer_names(root, mutation["proof"])
        else:
            require(mutation is None, f"{name}: only proven claims have proof mutations")
    unclaimed = manifest["unclaimed"]
    for name, reason in unclaimed.items():
        require(name in records, f"unclaimed names missing law {name}")
        require(name not in claimed, f"law both claimed and unclaimed: {name}")
        require(isinstance(reason, str) and reason.strip(), f"unclaimed law {name} needs a reason")
    missing = set(records) - claimed - set(unclaimed)
    require(not missing, f"laws without a claim or explicit exclusion: {sorted(missing)}")
    markers = [name for _, line, _ in visible_lines for name in MARKER.findall(line)]
    for name in markers:
        require(name in claims, f"README marker without entry: {name}")
    require(set(markers) == set(claims), f"claims without README marker: {sorted(set(claims) - set(markers))}")
    for claim in claims.values():
        require(any(claim["id"] in MARKER.findall(line) and claim["anchor"] in section
                    for _, line, section in visible_lines),
                f"{claim['id']}: marker not in declared README section")
    for number, line, _ in visible_lines:
        if "<!-- claim:" in line:
            require(line.count("<!-- claim:") == len(MARKER.findall(line)), f"README:{number}: malformed claim marker")
        if re.search(r"\bproven\b", line, re.I):
            ids = MARKER.findall(line)
            require(ids and any(claims[name]["status"] == "proven" and claims[name]["laws"] for name in ids),
                    f"README:{number}: proven statement needs a proven claim marker on the same line")
    return records, manifest


def link(value, kind, records, root):
    if kind == "law" and "#" not in value:
        return f"[`{value}`](../LAWS.bend#L{records[value].line})"
    path, _, name = value.partition("#")
    suffix = ""
    if name:
        source = local_path(root, path).read_text(encoding="utf-8").splitlines()
        pattern = (rf"^law {re.escape(name)}:" if kind == "law"
                   else rf"^\s*(?:async )?def {re.escape(name)}\(")
        number = next(i for i, line in enumerate(source, 1) if re.search(pattern, line))
        suffix = f"#L{number}"
    return f"[`{value}`](../{path}{suffix})"


def coverage(root):
    records, manifest = validate(root)
    claims = manifest["claims"]
    claimed = {law for c in claims for law in c["laws"] if "#" not in law}
    output = ["# Safety claim coverage", "", "Generated by `python3 tools/check-claims.py`. Do not edit this file.", "",
              f"The manifest records **{len(claims)} claims** and cites **{len(claimed)} of {len(records)} root laws**.",
              f"The remaining **{len(manifest['unclaimed'])} laws** have explicit reasons below.", "",
              "`proven` applies only to the stated pure-function scope. Its mutation is one negative",
              "control, not exhaustive mutation coverage. `tested` refers to executable checks, and",
              "`reviewed` records a code boundary without a formal guarantee. None is independent certification.",
              "The README badge reports the complete CI workflow, including `bend PROOF.bend --verdict`.",
              "It does not report an individual job or certify a pending pull request.", ""]
    output.extend(["Each mutation names a cited law and explains how its first failing observer relates",
                   "to that law. These relationships are reviewed source mappings, not additional proofs.",
                   "The checker validates the references and rejects ambiguous observer names across",
                   "the root proof's local import closure; Bend's diagnostic contains no source path.", ""])
    for claim in claims:
        output.extend([f"## {claim['id']}", "", f"**{claim['status']}**. {claim['claim']}", "",
                       f"[README statement](../README.md#{claim['anchor']}).", ""])
        for key, kind in (("laws", "law"), ("tests", "test"), ("code", "code")):
            output.append(f"- {key.capitalize()}: " + (", ".join(link(v, kind, records, root) for v in claim[key]) or "None.") )
        if "mutation" in claim:
            mutation = claim["mutation"]
            output.append(f"- Seeded bug: `{mutation['id']}` in `{mutation['path']}`. Expected rejection at `{mutation['proof']}`.")
            output.append(f"- Observer relationship to {link(mutation['law'], 'law', records, root)}: {mutation['observer_reason']}")
        output.append("")
    output.extend(["## Laws without a public claim", ""])
    for name, reason in manifest["unclaimed"].items():
        output.append(f"- {link(name, 'law', records, root)}. {reason}")
    return "\n".join(output) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        generated(args.root / "docs/PROOF-COVERAGE.md", coverage(args.root), args.check)
    except (ValueError, OSError, TypeError, KeyError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
