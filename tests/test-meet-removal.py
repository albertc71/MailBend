#!/usr/bin/env python3
"""Retired Meet extraction stays absent without changing ordinary mail reads."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LINK = "https://meet.google.com/abc-defg-hij"
TEXT = "é😀 \nhttps://meet.google.com/abc-defg-hij\n"


def no_extraction(value):
    if isinstance(value, dict):
        assert not {"facts", "facts_scan"}.intersection(value), value
        for child in value.values():
            no_extraction(child)
    elif isinstance(value, list):
        for child in value:
            no_extraction(child)


def text_contract(value):
    no_extraction(value)
    assert value["text"] == TEXT, value


def schema_contract(entries):
    names = {entry["name"] for entry in entries}
    assert {"mail_get", "mail_get_thread", "mail_get_new", "mail_search", "mail_brief"} <= names
    for entry in entries:
        no_extraction(entry["inputSchema"])
        no_extraction(entry["outputSchema"])
    get = next(entry for entry in entries if entry["name"] == "mail_get")
    assert get["inputSchema"]["required"] == ["uid"], get
    assert get["inputSchema"]["additionalProperties"] is False, get


def refusal_contract(code, result, traffic, records, tool="mail_get"):
    assert code != 0 and result == {"error": 'unknown argument "facts" for ' + tool}, result
    assert traffic == [] and records == [], (traffic, records)


def rejects(check, *args):
    try:
        check(*args)
    except AssertionError:
        return
    raise AssertionError("negative control was accepted")


def oracle_controls():
    text_contract({"text": TEXT})
    rejects(text_contract, {"text": TEXT.replace(LINK, "")})
    rejects(text_contract, {"text": TEXT, "facts": []})
    rejects(text_contract, {"text": TEXT, "facts_scan": {"limited": False}})
    rejects(no_extraction, {"messages": [{"facts": []}]})
    rejects(no_extraction, {"content": {"facts_scan": {}}})
    error = {"error": 'unknown argument "facts" for mail_get'}
    refusal_contract(1, error, [], [])
    rejects(refusal_contract, 0, {"text": TEXT}, [], [])
    rejects(refusal_contract, 1, error, ["LOGIN"], [])
    rejects(refusal_contract, 1, error, [], [{"body": "sent"}])
    rejects(refusal_contract, 1, error, [], [{"connect": "CONNECT wrong.example.test:443 HTTP/1.1",
                                            "env_names": [], "status": 403}])
    rejects(refusal_contract, 1, error, [], [{"connect": "CONNECT api.typesafe.ai:443 HTTP/1.1",
                                            "env_names": [], "tls_error": "synthetic handshake failure"}])
    entries = [{"name": name, "inputSchema": {"properties": {}, "required": ["uid"],
                 "additionalProperties": False}, "outputSchema": {"properties": {}}}
               for name in ("mail_get", "mail_get_thread", "mail_get_new", "mail_search", "mail_brief")]
    schema_contract(entries)
    for side in ("inputSchema", "outputSchema"):
        restored = copy.deepcopy(entries)
        restored[0][side]["properties"]["facts"] = {"type": "array"}
        rejects(schema_contract, restored)
    print("PASS removal oracles reject restored fields, altered mail and recorded-traffic refusals")


def fixture(e2e):
    result = copy.deepcopy(e2e.FIX)
    first = result["mailboxes"]["INBOX"]["messages"][0]
    first["raw"] = (
        "Message-ID: <msg1@example.com>\r\nFrom: alice@example.com\r\n"
        "To: tester@example.com\r\nSubject: Meeting\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n\r\n" + TEXT.encode().decode("latin-1"))
    long = copy.deepcopy(first)
    long["uid"] = 7
    long["raw"] = long["raw"].replace("<msg1@example.com>", "<long@example.com>") + "history " * 600
    result["mailboxes"]["INBOX"]["messages"].append(long)
    html = copy.deepcopy(first)
    html["uid"] = 8
    html["raw"] = ('Message-ID: <html@example.com>\r\nContent-Type: text/html\r\n\r\n'
                   '<a href="https://meet.google.com/abc-defg-hij">Join</a>')
    result["mailboxes"]["INBOX"]["messages"].append(html)
    return result


def public_reads(e2e, server):
    before = copy.deepcopy(server.st()["mailboxes"])
    replies, code = e2e.mcp_session(server, [e2e.modern_request(1, "tools/list")], legacy=False)
    assert code == 0 and len(replies) == 1, replies
    schema_contract(replies[0]["result"]["tools"])
    for extra in ({}, {"nested_message": False}, {"projection": "full"},
                  {"projection": "text", "max_response_bytes": 4096}):
        code, value = e2e.tool(server, "mail_get", {"uid": 1, **extra})
        assert code == 0, value
        text_contract(value)
    code, html = e2e.tool(server, "mail_get", {"uid": 1, "projection": "html"})
    assert code == 0 and html["html"] == "" and "text" not in html, html
    no_extraction(html)
    code, metadata = e2e.tool(server, "mail_get", {"uid": 1, "projection": "metadata"})
    assert code == 0 and "text" not in metadata and "html" not in metadata, metadata
    no_extraction(metadata)
    code, linked = e2e.tool(server, "mail_get", {"uid": 8})
    assert code == 0 and linked["html"] == '<a href="https://meet.google.com/abc-defg-hij">Join</a>', linked
    no_extraction(linked)
    for name, args, expected in (
            ("mail_search", {"body": "meet.google.com"}, [8, 7, 1]),
            ("mail_get_new", {"since_uid": 0, "limit": 20}, [1, 2, 3, 4, 5, 6, 7, 8]),
            ("mail_get_thread", {"uid": 1}, [1]),
            ("mail_brief", {"since_uid": 0, "limit": 20}, [1, 2, 3, 4, 5, 6, 7, 8])):
        code, value = e2e.tool(server, name, args)
        assert code == 0 and [message["uid"] for message in value["messages"]] == expected, value
        no_extraction(value)
    code, prefix = e2e.tool(server, "mail_get", {"uid": 7, "max_bytes": 1024})
    assert code == 0 and prefix["truncated"] is True and prefix["text"].startswith(TEXT), prefix
    no_extraction(prefix)
    code, shortened = e2e.tool(server, "mail_get", {"uid": 7, "projection": "text", "max_response_bytes": 2000})
    assert code == 0 and shortened["response"]["output_truncated"] is True, shortened
    assert shortened["text"].startswith(TEXT), shortened
    assert len(json.dumps(shortened, ensure_ascii=False, separators=(",", ":")).encode()) <= 2000
    no_extraction(shortened)
    assert server.st()["mailboxes"] == before, "read changed mailbox state"
    assert not any(" SELECT " in line or any(command in line for command in e2e.MUTATING_COMMANDS)
                   for line in server.log_lines()), server.log_lines()
    assert all("BODY.PEEK" in line for line in server.log_lines() if " UID FETCH " in line), server.log_lines()
    print("PASS discovery, whole/thread/multi-message output and bounded read preservation")


def rejected_arguments(e2e, server, work):
    ts = e2e.TypeSafe(work)
    try:
        env = e2e.jev_env(ts, e2e.typesafe_key_file(work),
                          MAILBEND_TYPESAFE_CONTENT="body", MAILBEND_TYPESAFE_ZERO_RETENTION="1")
        for old in (True, False, None, "yes"):
            for extra in ({}, {"section": "1", "uidvalidity": 1700000001, "nested_message": True}):
                start, recorded = len(server.log_records()), len(ts.records())
                code, value = e2e.tool(server, "mail_get", {"uid": 1, "facts": old, **extra}, **env)
                refusal_contract(code, value, server.log_records()[start:], ts.records()[recorded:])
        for name, args in (("mail_get_thread", {"uid": 1}), ("mail_get_new", {}),
                           ("mail_search", {}), ("mail_brief", {})):
            start, recorded = len(server.log_records()), len(ts.records())
            code, value = e2e.tool(server, name, {**args, "facts": True}, **env)
            refusal_contract(code, value, server.log_records()[start:], ts.records()[recorded:], name)
        args = {"uid": 1, "projection": "text", "max_response_bytes": 4096}
        code, value, commands, asked = e2e.gate_call(server, ts, "mail_get", args, **env)
        text_contract(value)
        assert code == 0 and value["jev"]["status"] == "checked" and value["jev"]["content"] == "body", value
        assert any(email.get("text") == TEXT for request in asked
                   for email in request["body"]["state"]["emails"]), asked
        code, repeated, observed, sent = e2e.gate_call(
            server, ts, "mail_get", {**args, "nested_message": False}, **env)
        assert code == 0 and repeated == value and observed == commands, repeated
        assert [request["body"] for request in sent] == [request["body"] for request in asked]
        print("PASS retired arguments refuse with no recorded traffic and ordinary Jev requests keep original text")
    finally:
        ts.stop()


def prefix_metadata(e2e, work):
    data = fixture(e2e)
    header = ("Message-ID: <boundary@example.com>\r\nFrom: alice@example.com\r\n"
              "To: tester@example.com\r\nSubject: Boundary\r\n"
              "Content-Type: text/plain; charset=us-ascii\r\n\r\n")
    first = data["mailboxes"]["INBOX"]["messages"][0]
    window = header + " " * (1024 - len(header) - 36) + LINK + ".evil.invalid"
    data["mailboxes"]["INBOX"]["messages"] = [
        {**first, "uid": 1, "raw": window, "reported_size": 1024},
        {**first, "uid": 2, "raw": header + LINK, "reported_size": 1},
        {**first, "uid": 3, "raw": header + LINK},
        {**first, "uid": 4, "raw": header + LINK + "\n", "reported_size": 1}]
    server = e2e.Server(work, fixture=data)
    try:
        before = copy.deepcopy(server.st()["mailboxes"])
        for uid in (1, 2, 3, 4):
            code, value = e2e.tool(server, "mail_get", {"uid": uid, "max_bytes": 1024})
            assert code == 0 and value["truncated"] is False, value
            no_extraction(value)
            if uid == 1:
                assert value["text"].endswith(LINK), value
            else:
                assert value["text"] == (LINK + "\n" if uid == 4 else LINK), value
        assert server.st()["mailboxes"] == before
    finally:
        server.stop()
    print("PASS complete EOF and inconsistent-size prefix behavior stay unchanged")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controls-only", action="store_true")
    args = parser.parse_args()
    oracle_controls()
    if args.controls_only:
        return
    spec = importlib.util.spec_from_file_location("e2e", ROOT / "tests/test-e2e.py")
    e2e = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(e2e)
    with tempfile.TemporaryDirectory(prefix="mailbend-meet-removal-") as work:
        subprocess.run(["sh", str(ROOT / "tests/gen-test-certs.sh"), str(Path(work) / "certs")],
                       check=True, capture_output=True, timeout=30)
        server = e2e.Server(work, fixture=fixture(e2e))
        try:
            before = copy.deepcopy(server.st()["mailboxes"])
            public_reads(e2e, server)
            rejected_arguments(e2e, server, work)
            assert server.st()["mailboxes"] == before
            assert all(ok for _, ok in e2e.results), e2e.results
            assert not any(secret in output for secret in (e2e.PASSWORD, e2e.TYPESAFE_KEY)
                           for output in e2e.outputs), "synthetic credential leaked"
        finally:
            server.stop()
        prefix_metadata(e2e, work)
        assert all(ok for _, ok in e2e.results), e2e.results
        assert not any(secret in output for secret in (e2e.PASSWORD, e2e.TYPESAFE_KEY)
                       for output in e2e.outputs), "synthetic credential leaked"
    print("PASS removal contract through the selected CLI/MCP transport")


if __name__ == "__main__":
    main()
