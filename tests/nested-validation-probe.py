"""Hosted-only, exact-source nested-read probes. Never run on a user computer."""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHA = "79048a8262880dc10eb8986e56d6305d762ef278c052a6f935656f2a7e981a59"
MUTATIONS_SHA = "f8aafbb9ba8b26a7e6ca39d449eab3944408f3a8cac2fe6017f8bb3572f0c8ce"
CASES = {
    "message-depth": ("public", "nested forward-depth literal view", "nested apple-style-attached literal view"),
    "entity-credit": ("resources", "nested resource entities-over", "nested resource entities-at"),
    "parse-one-byte": ("resources", "nested resource parse-over", "nested resource parse-at"),
    "view-one-character": ("resources", "nested resource view-over", "nested resource view-at"),
    "reset-sibling-fuel": ("resources", "nested resource message-siblings-over", "nested resource message-siblings-at"),
    "qp-terminal": ("public", "nested bad-qp-terminal refuses atomically", "nested qp literal view"),
    "base64-canonical": ("public", "nested bad-base64-2 refuses atomically", "nested base64 literal view"),
    "header-sanitizer": ("public", "nested sanitized-headers literal view", "nested apple-style-attached literal view"),
    "omit-propagation": ("public", "nested forward-depth literal view", "nested apple-style-attached literal view"),
    "legacy-false-route": ("legacy", "ordinary selected literal bytes text/plain", "ordinary whole literal bytes"),
    "nested-privacy": ("annotations", "nested Jev never transmits inner markers", "Jev capture observes ordinary text positive control"),
    "scope-removed": ("annotations", "nested scoped Jev ok body", "Jev capture observes ordinary text positive control"),
    "atomic-exact-fit": ("response", "nested exact serialized fit", "nested one byte short is atomic"),
    "schema-opaque-complete": ("schema", "opaque complete message rejected", "complete nested literal accepted"),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def data(path):
    return os.readlink(path).encode() if path.is_symlink() else path.read_bytes()


def manifest():
    raw = (ROOT / "tests/nested-validation-source.json").read_bytes()
    if digest(raw) != SOURCE_SHA:
        raise ValueError("Source manifest differs from the reviewed generation boundary")
    return json.loads(raw)


def mutations():
    raw = (ROOT / "tests/nested-validation-mutations.json").read_bytes()
    if digest(raw) != MUTATIONS_SHA:
        raise ValueError("Mutation descriptors differ from the reviewed packet")
    return {entry["name"]: entry for entry in json.loads(raw)["mutations"]}


def guard(except_path=None):
    source = manifest()
    tracked = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True,
                             capture_output=True, timeout=30).stdout.decode().split("\0")
    expected = set(source["files"]) | {"tests/nested-validation-source.json",
        "tests/nested-validation-mutations.json", "tests/nested-validation-probe.py",
        ".github/workflows/nested-read-validation.yml"}
    if set(filter(None, tracked)) != expected:
        raise ValueError("Tracked source inventory differs from the reviewed product plus proposal")
    for name, item in source["files"].items():
        path = ROOT / name
        if item["mode"] == "120000":
            if not path.is_symlink():
                raise ValueError("Expected tracked symlink: " + name)
        elif path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(ROOT.resolve()):
            raise ValueError("Unexpected source type/path: " + name)
        elif ("100755" if path.stat().st_mode & 0o111 else "100644") != item["mode"]:
            raise ValueError("Source executable mode changed: " + name)
        if name != except_path and digest(data(path)) != item["sha256"]:
            raise ValueError("Source identity changed: " + name)
    return source["candidate_tree"]


def apply(name, receipt):
    entry = mutations()[name]
    tree = guard()
    path = ROOT / entry["path"]
    before = path.read_text()
    if before.count(entry["old"]) != 1:
        raise ValueError("Mutation anchor is not unique")
    after = before.replace(entry["old"], entry["new"], 1)
    path.write_text(after, encoding="utf-8", newline="\n")
    receipt.write_text(json.dumps({"mutation": name, "source_tree": tree,
        "path": entry["path"], "before_sha256": digest(before.encode()),
        "after_sha256": digest(after.encode())}, indent=2) + "\n")


def schema_checks(test, nested):
    value = nested.result(nested.node("inner", "hello"))
    validator = test.OUTPUT_VALIDATORS["mail_get"]
    test.check("complete nested literal accepted", validator.is_valid(value))
    opaque = nested.node(attachments=[{"filename": "", "content_type": "message/rfc822", "size": 23}])
    child = nested.node(attachments=[{"filename": "", "content_type": "message/rfc822", "size": 23, "message": opaque}])
    root = nested.node(attachments=[{"filename": "", "content_type": "message/rfc822", "size": 23, "message": child}])
    test.check("opaque complete message rejected", not validator.is_valid(nested.result(root)))


def intended_witness(name, call, actual, detail, nested):
    request = call.get("request", {})
    code = call.get("code")
    if name == "schema-opaque-complete":
        return {"kind": "opaque_complete_accepted"}
    if not call.get("well_formed"):
        return None
    if name == "legacy-false-route":
        expected = {"error": "nested_message requires a message/rfc822 or message/global section"}
        if request == {"uid": 1, "uidvalidity": 9, "section": "1", "nested_message": False} and code == 1 and actual == expected:
            return {"kind": "explicit_false_enters_nested_discovery", "error": expected["error"]}
        return None
    if request.get("nested_message") is not True or request.get("section") != "1" or request.get("uidvalidity") != 9:
        return None
    if name == "atomic-exact-fit":
        size = nested.with_budget(nested.result(nested.node("inner", "hello")))["response"]["max_bytes"]
        error = f"max_response_bytes is too small for the complete nested representation: need {size}; raise the response budget or retry without nested_message"
        if request == nested.args(max_response_bytes=size) and code == 1 and actual == {"error": error}:
            return {"kind": "exact_fit_rejected_by_size_comparison", "size": size, "error": error}
        return None
    if code != 0 or not isinstance(actual, dict) or "error" in actual:
        return None
    if name in {"qp-terminal", "base64-canonical"}:
        case = "bad-qp-terminal" if name == "qp-terminal" else "bad-base64-2"
        uid = next(i for i, item in enumerate(nested.cases(), 1) if item[0] == case)
        if request == nested.args(uid=uid) and call["schema_valid"] and actual.get("content_encoding") == "message" and actual.get("uid") == uid:
            return {"kind": "malformed_required_encoding_accepted", "fixture": case}
        return None
    if name in {"entity-credit", "parse-one-byte", "view-one-character", "reset-sibling-fuel"}:
        if request != nested.args(max_bytes=16777216) or not call["schema_valid"]:
            return None
        if name == "entity-credit":
            value = nested.node()
        elif name == "parse-one-byte":
            size = (16777216 - len(b"Content-Type: application/octet-stream\r\n\r\n")) // 2
            value = nested.node(attachments=[{"filename": "", "content_type": "application/octet-stream", "size": size}])
        elif name == "view-one-character":
            value = nested.node(text="x" * 4194305)
        else:
            value = nested.node(attachments=[{"filename": "", "content_type": "message/rfc822", "size": 23,
                "message": nested.node("inner", "hello")} for _ in range(64)])
        if actual == nested.result(value):
            return {"kind": "over_limit_literal_accepted", "limit": name}
        return None
    if name in {"message-depth", "omit-propagation", "header-sanitizer"}:
        case = "sanitized-headers" if name == "header-sanitizer" else "forward-depth"
        uid, entry = next((i, item) for i, item in enumerate(nested.cases(), 1) if item[0] == case)
        value = copy.deepcopy(entry[2]["expected"])
        if name == "header-sanitizer":
            value["headers"] = {key: "=?utf-8?Q?A=0D=0AB=09C=7F?=" for key in value["headers"]}
        else:
            nodes = [value]
            for _ in range(2):
                nodes.append(nodes[-1]["attachments"][0]["message"])
            for node in (nodes if name == "message-depth" else nodes[:2]):
                node["parse_complete"], node["omissions"] = True, []
            if name == "message-depth":
                nodes[2]["attachments"][0]["message"] = nested.node("four", "hidden")
        if request == nested.args(uid=uid) and actual == nested.result(value, uid):
            return {"kind": "exact_changed_nested_literal", "fixture": case,
                    "schema_valid": call["schema_valid"], "change": name}
        return None
    value = nested.node("INNER_HEADER_MARKER", "INNER_BODY_MARKER")
    if request != nested.args() or call.get("content_mode") != "body" or actual.get("content") != value:
        return None
    annotation = actual.get("jev", {})
    if name == "nested-privacy" and call["schema_valid"] and annotation.get("status") == "checked":
        captured = json.loads(detail) if isinstance(detail, str) else None
        if isinstance(captured, list) and captured and ("INNER_HEADER_MARKER" in detail or "INNER_BODY_MARKER" in detail):
            return {"kind": "synthetic_inner_marker_in_nonempty_body_request", "capture": captured}
    if name == "scope-removed":
        expected = nested.result(value)
        expected["jev"] = {"status": "checked", "model": "jev-1.14.0", "content": "body",
            "derived_from_untrusted_content": True, "decision": "proceeded", "reasons": [],
            "signals": {"reply_needed": "low", "action_required": "mid", "priority": "mid",
                        "category": None, "suggested_action": "read_later"}}
        if actual == expected:
            return {"kind": "exact_annotation_missing_nested_scope", "schema_valid": call["schema_valid"]}
    return None


def probe(name, output, receipt=None):
    group, target, positive = CASES[name]
    change = None
    if receipt is None:
        guard()
    else:
        change = json.loads(receipt.read_text())
        entry = mutations()[name]
        if change["mutation"] != name or change["path"] != entry["path"]:
            raise ValueError("Mutation receipt mismatch")
        guard(entry["path"])
        changed = (ROOT / entry["path"]).read_text()
        if digest(changed.encode()) != change["after_sha256"]:
            raise ValueError("Mutated source does not match its receipt")
        if (change["source_tree"] != manifest()["candidate_tree"] or
                change["before_sha256"] != manifest()["files"][entry["path"]]["sha256"] or
                changed.count(entry["new"]) != 1 or
                digest(changed.replace(entry["new"], entry["old"], 1).encode()) != change["before_sha256"]):
            raise ValueError("Mutation is not the exact reviewed replacement")
    sys.path.insert(0, str(ROOT / "tests"))
    import nested_reads
    spec = importlib.util.spec_from_file_location("nested_validation_e2e", ROOT / "tests/test-e2e.py")
    test = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = test
    spec.loader.exec_module(test)
    records = []
    calls = []
    last = {}
    answer_for_check = None
    call_number = 0
    original_tool, original_check = test.tool, test.check
    original_wire = nested_reads.wire
    original_mcp_session = test.mcp_session

    def begin(request, content_mode=None):
        nonlocal call_number, answer_for_check
        call_number += 1
        answer_for_check = None
        last.clear()
        last.update({"id": call_number, "request": dict(request), "content_mode": content_mode,
                     "well_formed": False, "schema_valid": False,
                     "transport_ok": os.environ["MAILBEND_TEST_MCP"] == "0"})

    def observed_mcp_session(*args, **kwargs):
        replies, raw_status = original_mcp_session(*args, **kwargs)
        initialized = (len(replies) == 2 and replies[0].get("jsonrpc") == "2.0" and replies[0].get("id") == 0 and
            replies[0].get("result", {}).get("protocolVersion") == "2025-06-18" and
            replies[0].get("result", {}).get("serverInfo", {}).get("name") == "mailbend")
        shared = False
        if len(replies) == 2 and replies[1].get("jsonrpc") == "2.0" and replies[1].get("id") == 1:
            result = replies[1].get("result", {})
            content = result.get("content", [])
            if len(content) == 1 and content[0].get("type") == "text" and type(result.get("isError")) is bool:
                value = json.loads(content[0]["text"])
                shared = (isinstance(value, dict) and result.get("structuredContent") == value and
                          result["isError"] == (set(value) == {"error"}))
        last.update({"mcp_process_status": raw_status, "mcp_initialized": initialized,
                     "mcp_shared_value": shared,
                     "transport_ok": raw_status == 0 and initialized and shared and last.get("mcp_legacy_initialized") is True})
        return replies, raw_status

    def finish(code, answer):
        nonlocal answer_for_check
        answer_for_check = answer
        last.update({"code": code, "well_formed": last["transport_ok"] and isinstance(answer, dict) and code in (0, 1) and
                     "unparsed" not in answer and (code == 0 or isinstance(answer.get("error"), str)),
                     "schema_valid": test.OUTPUT_VALIDATORS["mail_get"].is_valid(answer),
                     "answer_sha256": digest(json.dumps(answer, ensure_ascii=False, sort_keys=True).encode())})
        calls.append({"mode": os.environ["MAILBEND_TEST_MCP"], **last})

    def observed_tool(*args, **kwargs):
        begin(args[2] if len(args) > 2 else kwargs.get("args", {}), kwargs.get("MAILBEND_TYPESAFE_CONTENT"))
        code, answer = original_tool(*args, **kwargs)
        finish(code, answer)
        return code, answer

    def observed_wire(*args, **kwargs):
        begin(args[2] if len(args) > 2 else kwargs["request"])
        code, rendered = original_wire(*args, **kwargs)
        try:
            answer = json.loads(rendered)
        except json.JSONDecodeError:
            answer = None
        finish(code, answer)
        return code, rendered

    def observed_check(label, ok, detail=""):
        if label == "MCP fixture initializes legacy protocol":
            last["mcp_legacy_initialized"] = bool(ok)
        witness = intended_witness(name, last, answer_for_check, detail, nested_reads) if label == target and not ok else None
        records.append({"mode": os.environ["MAILBEND_TEST_MCP"], "name": label,
                        "ok": bool(ok), "call": dict(last), "intended_witness": witness})
        original_check(label, ok, detail)

    test.tool, test.check = observed_tool, observed_check
    test.mcp_session = observed_mcp_session
    nested_reads.wire = observed_wire
    with tempfile.TemporaryDirectory(prefix="nested-hosted-probe-") as work:
        if group != "schema":
            subprocess.run(["sh", str(ROOT / "tests/gen-test-certs.sh"), str(Path(work) / "certs")],
                           check=True, timeout=30, capture_output=True)
        for mode in (("schema",) if group == "schema" else ("0", "1")):
            os.environ["MAILBEND_TEST_MCP"] = mode
            last.clear()
            if group == "schema":
                schema_checks(test, nested_reads)
            else:
                functions = {"public": nested_reads.public_reads, "legacy": nested_reads.legacy_reads,
                    "annotations": nested_reads.annotations, "response": nested_reads.response_budget,
                    "resources": nested_reads.resource_reads}
                functions[group](test, work)
        captures = []
        for path in sorted(Path(work).glob("typesafe-*.jsonl")):
            if path.is_symlink() or path.stat().st_size > 1048576:
                raise ValueError("Unexpected synthetic capture size/type")
            captures.append({"name": path.name, "records": [json.loads(line)
                             for line in path.read_text().splitlines() if line.strip()]})
        captured = json.dumps(captures, indent=2) + "\n"
        if len(captured.encode()) > 1048576:
            raise ValueError("Synthetic request captures exceed the report limit")
        output.with_suffix(".captures.json").write_text(captured)
    report = {"source_tree": manifest()["candidate_tree"], "mutation": name, "group": group, "target": target, "positive_control": positive,
              "records": records, "calls": calls, "probe_completed": True, "mutation_receipt": change,
              "core_sha256": digest((ROOT / "bin/mailbend-core").read_bytes())}
    output.write_text(json.dumps(report, indent=2) + "\n")
    if receipt is None and not all(x["ok"] for x in records):
        raise ValueError("Unmodified control probe did not pass")
    if receipt is None and group != "schema" and (not calls or not all(
            x["transport_ok"] and x["well_formed"] and x["schema_valid"] for x in calls)):
        raise ValueError("Unmodified control contains an incomplete transport or invalid result")


def judge(name, baseline, mutant):
    first, second = json.loads(baseline.read_text()), json.loads(mutant.read_text())
    group, target, positive = CASES[name]
    if first["mutation"] != name or second["mutation"] != name or not first["probe_completed"] or not second["probe_completed"]:
        raise ValueError("Probe identity or completion mismatch")
    if not first["records"] or not all(x["ok"] for x in first["records"]):
        raise ValueError("No passing unmodified control")
    if first["mutation_receipt"] is not None or second["mutation_receipt"] is None or first["source_tree"] != second["source_tree"]:
        raise ValueError("Unmodified/mutated source identity is missing")
    for report in (first, second):
        if group == "schema":
            if report["calls"]:
                raise ValueError("Schema-only probe unexpectedly made a public call")
        elif not report["calls"] or not all(x["transport_ok"] and x["well_formed"] for x in report["calls"]):
            raise ValueError("Observed transport or malformed-result failure is not a mutation kill")
    if not all(x["schema_valid"] for x in first["calls"]):
        raise ValueError("Unmodified control contains a schema-invalid response")
    if any((x["name"].startswith("mcp shared value:") or x["name"] == "MCP fixture initializes legacy protocol") and not x["ok"] for x in second["records"]):
        raise ValueError("MCP transport representations disagree")
    killed = []
    for mode in (("schema",) if group == "schema" else ("0", "1")):
        controls = [x for x in first["records"] if x["mode"] == mode]
        def clean_control(row):
            return row["ok"] and (mode == "schema" or (row["call"].get("transport_ok") and
                row["call"].get("well_formed") and row["call"].get("schema_valid")))
        if not any(x["name"] == target and clean_control(x) for x in controls) or not any(x["name"] == positive and clean_control(x) for x in controls):
            raise ValueError("The unmodified target/positive pair was not observed: " + mode)
        rows = [x for x in second["records"] if x["mode"] == mode]
        witnesses = [x for x in rows if x["name"] == target and not x["ok"] and x["intended_witness"]]
        control_passed = any(x["name"] == positive and x["ok"] and
                            (mode == "schema" or (x["call"].get("well_formed") and x["call"].get("schema_valid"))) for x in rows)
        target_failed = bool(witnesses)
        if not target_failed or not control_passed:
            raise ValueError("Intended behavioral discriminator did not kill the mutation: " + mode)
        label = "schema" if mode == "schema" else ("cli" if mode == "0" else "mcp")
        killed.append({"mode": label, "target": target, "positive": positive,
                       "calls": [{"call": x["call"], "witness": x["intended_witness"]} for x in witnesses]})
    print(json.dumps({"mutation": name, "behavioral_kill": True, "witnesses": killed,
                     "baseline_sha256": digest(baseline.read_bytes()),
                     "mutant_sha256": digest(mutant.read_bytes()),
                     "schema_only": group == "schema"}, sort_keys=True))


parser = argparse.ArgumentParser(description=__doc__)
sub = parser.add_subparsers(dest="action", required=True)
sub.add_parser("guard")
for action in ("apply", "probe", "judge"):
    command = sub.add_parser(action)
    command.add_argument("name", choices=sorted(CASES))
    if action == "apply":
        command.add_argument("receipt", type=Path)
    elif action == "probe":
        command.add_argument("output", type=Path)
        command.add_argument("--receipt", type=Path)
    else:
        command.add_argument("baseline", type=Path)
        command.add_argument("mutant", type=Path)
args = parser.parse_args()
if args.action == "guard":
    print(json.dumps({"verified_source_tree": guard(), "files": len(manifest()["files"])}))
elif args.action == "apply":
    apply(args.name, args.receipt)
elif args.action == "probe":
    probe(args.name, args.output, args.receipt)
else:
    judge(args.name, args.baseline, args.mutant)
