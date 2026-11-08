"""Independent literal selected-message contracts at the CLI/MCP boundary."""
import base64
import copy
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "tests/corpus/nested"
HEADER_REASON = "Only parent header facts were eligible for checking; nested headers and text were not included."
BODY_REASON = "Nested message text was not included in the Jev request."


def cases():
    paths = sorted(CORPUS.glob("*.eml"))
    assert paths and {p.stem for p in paths} == {p.stem for p in CORPUS.glob("*.json")}
    for path in paths:
        data = json.loads(path.with_suffix(".json").read_text())
        assert data["source"]["kind"] == "synthetic" and data["source"]["license"] == "MIT"
        assert data["references"] and ("expected" in data) != ("error" in data)
        yield path.stem, path.read_bytes(), data


def node(subject="", text="", attachments=None, omissions=None):
    return {"headers": {"from": "", "to": "", "subject": subject, "date": "", "message_id": ""},
            "text": text, "attachments": attachments or [],
            "parse_complete": not omissions, "omissions": omissions or []}


def message(raw, uid=1, media="message/rfc822", parameters="NIL"):
    encoded = base64.b64encode(raw).decode("ascii")
    main, sub = media.upper().split("/")
    suffix = " NIL NIL 1" if main == "MESSAGE" else (" 1" if main == "TEXT" else "")
    return {"uid": uid, "flags": [], "internaldate": "08-Nov-2026 12:00:00 +0000",
            "raw": "From: parent@example.test\r\nTo: reader@example.test\r\nSubject: parent\r\n"
                   f"Content-Type: {media}\r\nContent-Transfer-Encoding: base64\r\n\r\n{encoded}",
            "bodystructure": f'("{main}" "{sub}" {parameters} NIL NIL "BASE64" {len(encoded)}{suffix} NIL NIL NIL NIL)',
            "section_payloads": {"1": encoded}}


def fixture(test, messages):
    value = copy.deepcopy(test.FIX)
    value["mailboxes"]["INBOX"].update(uidvalidity=9, uidnext=len(messages) + 1, messages=messages)
    return value


def result(content, uid=1, media="message/rfc822"):
    return {"folder": "INBOX", "uid": uid, "uidvalidity": 9, "section": "1",
            "content_type": media, "complete": True, "scope": "selected_part",
            "message_complete": False, "content": content, "content_encoding": "message"}


def args(**extra):
    return {"uid": 1, "uidvalidity": 9, "section": "1", "nested_message": True, **extra}


def commands(server, start=0):
    return [re.sub(r"^[^ ]+ ", "", r["line"]) for r in server.log_records()[start:]
            if r["proto"] == "imap" and re.search(r" (?:EXAMINE|SELECT|UID|APPEND|STORE|LIST) ", r["line"])]


def wire(test, server, request):
    if os.environ.get("MAILBEND_TEST_MCP") == "1":
        replies, code = test.mcp_session(server, [
            {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "mail_get", "arguments": request}}])
        answer = replies[-1]["result"]
        return (1 if answer["isError"] else code), answer["content"][0]["text"]
    proc = subprocess.run([test.LAUNCHER, "call", "mail_get", json.dumps(request)],
                          env=server.env(), capture_output=True, text=True, timeout=120)
    return proc.returncode, proc.stdout.rstrip("\n")


def public_reads(test, work):
    all_cases = list(cases())
    mails = [message(raw, uid, data.get("media_type", data.get("selected_type", "message/rfc822")),
                     data.get("bodystructure_parameters", "NIL"))
             for uid, (_, raw, data) in enumerate(all_cases, 1)]
    server = test.Server(work, fixture=fixture(test, mails))
    try:
        initial = copy.deepcopy(server.st()["mailboxes"]["INBOX"])
        for uid, (name, raw, data) in enumerate(all_cases, 1):
            start = len(server.log_records())
            code, actual = test.tool(server, "mail_get", args(uid=uid), MAILBEND_READ_ONLY="1")
            if "error" in data:
                test.check("nested " + name + " refuses atomically", code != 0 and
                           set(actual) == {"error"} and data["error"] in actual["error"] and
                           "retry without nested_message" in actual["error"], actual)
            else:
                test.check("nested " + name + " literal view", code == 0 and actual ==
                           result(data["expected"], uid, data.get("selected_type", "message/rfc822")), actual)
            observed = commands(server, start)
            test.check("nested " + name + " exact selected plan", observed == [
                'EXAMINE "INBOX"', f'UID FETCH {uid} (UID BODYSTRUCTURE)', 'EXAMINE "INBOX"',
                f'UID FETCH {uid} (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-ID LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST AUTO-SUBMITTED PRECEDENCE)] BODYSTRUCTURE BODY.PEEK[1]<0.262144>)'], observed)
            if "legacy_base64" in data:
                golden = ('{"folder":"INBOX","uid":' + str(uid) + ',"uidvalidity":9,"section":"1",'
                          '"content_type":"message/rfc822","complete":true,"scope":"selected_part",'
                          '"message_complete":false,"content":"U3ViamVjdDogaW5uZXINCg0KaGVsbG8=",'
                          '"content_encoding":"base64"}')
                for option in ({}, {"nested_message": False}):
                    status, rendered = wire(test, server, {"uid": uid, "uidvalidity": 9, "section": "1", **option})
                    test.check("nested absent/false preserves literal legacy bytes", status == 0 and rendered == golden, rendered)
        test.check("nested corpus preserves mailbox state", server.st()["mailboxes"]["INBOX"] == initial)
        for bad in [args(section=""), args(section="list"), args(section="text"), args(section="html"),
                    args(section="01"), args(section="1.0"), args(section="1."), args(section="1] STORE 1"),
                    args(uidvalidity=0), args(projection="text"), args(projection="html"),
                    args(projection="metadata"), args(nested_message="true"), args(nested_message=None)]:
            start = len(server.log_records())
            code, actual = test.tool(server, "mail_get", bad)
            test.check("nested malformed/unsupported request has no IMAP traffic", code != 0 and
                       len(server.log_records()) == start, actual)
    finally:
        server.stop()



def legacy_reads(test, work):
    examples = [("text/plain", b"hello", "hello", "text"),
                ("text/html", b"<b>hello</b>", "<b>hello</b>", "text"),
                ("application/octet-stream", b"hello", "aGVsbG8=", "base64")]
    for media, raw, content, encoding in examples:
        server = test.Server(work, fixture=fixture(test, [message(raw, media=media)]))
        try:
            golden = ('{"folder":"INBOX","uid":1,"uidvalidity":9,"section":"1",'
                      '"content_type":' + json.dumps(media) + ',"complete":true,"scope":"selected_part",'
                      '"message_complete":false,"content":' + json.dumps(content) + ',"content_encoding":' +
                      json.dumps(encoding) + '}')
            for option in ({}, {"nested_message": False}):
                status, rendered = wire(test, server, {"uid": 1, "uidvalidity": 9, "section": "1", **option})
                test.check("ordinary selected literal bytes " + media, status == 0 and rendered == golden, rendered)
            start = len(server.log_records())
            code, actual = test.tool(server, "mail_get", args())
            test.check("non-message nested request stops after discovery", code != 0 and commands(server, start) ==
                       ['EXAMINE "INBOX"', 'UID FETCH 1 (UID BODYSTRUCTURE)'], actual)
        finally:
            server.stop()
    ordinary = {"uid": 1, "flags": [], "internaldate": "08-Nov-2026 12:00:00 +0000",
                "raw": "Subject: simple\r\n\r\nhello"}
    golden = ('{"folder":"INBOX","uid":1,"uidvalidity":9,"flags":[],"seen":false,'
              '"internal_date":"08-Nov-2026 12:00:00 +0000","size":24,"truncated":false,'
              '"from":"","to":"","cc":"","reply_to":"","subject":"simple","date":"",'
              '"message_id":"","in_reply_to":"","references":"","text":"hello","html":"",'
              '"html_available":false,"attachments":[],"list_id":null,"auto_submitted":null,"bulk":null,'
              '"unsubscribe":{"mailto":null,"https":null,"one_click":false},"answered":false,"forwarded":false}')
    server = test.Server(work, fixture=fixture(test, [ordinary]))
    try:
        for option in ({}, {"nested_message": False}):
            status, rendered = wire(test, server, {"uid": 1, "uidvalidity": 9, **option})
            test.check("ordinary whole literal bytes", status == 0 and rendered == golden, rendered)
    finally:
        server.stop()

def resource_reads(test, work):
    header = b"Content-Type: application/octet-stream\r\n\r\n"
    assert len(header) % 2 == 0
    body_size = (16777216 - len(header)) // 2
    binary = header + b"x" * body_size
    wide = b"Content-Type: multipart/mixed; boundary=b\r\n\r\n"
    shapes = [("entities-at", wide + b"--b\r\n\r\n\r\n" * 127 + b"--b--", node(), None),
              ("entities-over", wide + b"--b\r\n\r\n\r\n" * 128 + b"--b--", None, "128 MIME entity"),
              ("parse-at", binary, node(attachments=[{"filename": "", "content_type": "application/octet-stream", "size": body_size}]), None),
              ("parse-over", header[:-4] + b" " + header[-4:] + b"x" * body_size,
               None, "aggregate parse-byte"),
              ("view-at", b"\r\n" + b"x" * 4194304, node(text="x" * 4194304), None),
              ("view-over", b"\r\n" + b"x" * 4194305, None, "UTF-8 view")]
    attached = b"--b\r\nContent-Type: message/rfc822\r\n\r\nSubject: inner\r\n\r\nhello\r\n"
    entries = [{"filename": "", "content_type": "message/rfc822", "size": 23,
                "message": node("inner", "hello")} for _ in range(63)]
    shapes += [("message-siblings-at", wide + attached * 63 + b"--b\r\n\r\n\r\n--b--",
                node(attachments=entries), None),
               ("message-siblings-over", wide + attached * 64 + b"--b--", None, "128 MIME entity"),
               ("huge-header-at", b"Subject: " + b"h" * 4194304 + b"\r\n\r\n", node("h" * 998), None),
               ("huge-header-over", b"Subject: " + b"h" * 4194305 + b"\r\n\r\n", None, "UTF-8 view")]
    for name, raw, expected, error in shapes:
        server = test.Server(work, fixture=fixture(test, [message(raw)]))
        try:
            code, actual = test.tool(server, "mail_get", args(max_bytes=16777216))
            test.check("nested resource " + name, (code != 0 and error in actual.get("error", "")) if error
                       else code == 0 and actual == result(expected))
        finally:
            server.stop()


def annotations(test, work):
    raw = b"Subject: INNER_HEADER_MARKER\r\n\r\nINNER_BODY_MARKER"
    expected = node("INNER_HEADER_MARKER", "INNER_BODY_MARKER")
    plain = test.plain_message(2, "ordinary", "VISIBLE_CONTROL")
    server = test.Server(work, fixture=fixture(test, [message(raw), plain]))
    key = test.typesafe_key_file(work)
    try:
        for scenario, mode in [("ok", "headers"), ("ok", "body"), ("status:503", "body"), ("malformed", "headers")]:
            ts = test.TypeSafe(work, scenario)
            try:
                env = test.jev_env(ts, key, MAILBEND_TYPESAFE_CONTENT=mode, MAILBEND_TYPESAFE_ZERO_RETENTION="1")
                code, actual = test.tool(server, "mail_get", args(), **env)
                annotation = actual.get("jev", {})
                reason = HEADER_REASON if mode == "headers" else BODY_REASON
                test.check("nested scoped Jev " + scenario + " " + mode, code == 0 and
                           actual.get("content") == expected and annotation.get("coverage") ==
                           ("headers_only" if mode == "headers" else "partial") and
                           annotation.get("status") == ("checked" if scenario == "ok" else "unchecked") and
                           reason in annotation.get("reasons", []) and
                           (scenario == "ok" or len(annotation["reasons"]) >= 2), actual)
                captured = json.dumps([x["body"] for x in ts.requests()], ensure_ascii=False)
                test.check("nested Jev never transmits inner markers", ts.requests() and
                           "INNER_HEADER_MARKER" not in captured and "INNER_BODY_MARKER" not in captured, captured)
                if scenario == "ok":
                    literal = result(expected)
                    literal["jev"] = {"status": "checked", "model": "jev-1.14.0", "content": mode,
                        "derived_from_untrusted_content": True, "decision": "proceeded", "reasons": [reason],
                        "signals": {"reply_needed": "low", "action_required": "mid", "priority": "mid",
                                    "category": None, "suggested_action": "read_later"},
                        "coverage": "headers_only" if mode == "headers" else "partial"}
                    sized = with_budget(literal)
                    size = sized["response"]["max_bytes"]
                    code, budgeted = test.tool(server, "mail_get", args(max_response_bytes=size), **env)
                    test.check("nested final Jev scope included in exact fit " + mode,
                               code == 0 and budgeted == sized, budgeted)
                    code, budgeted = test.tool(server, "mail_get", args(max_response_bytes=size - 1), **env)
                    test.check("nested final Jev scope one byte short is atomic " + mode,
                               code != 0 and set(budgeted) == {"error"} and
                               "complete nested representation" in budgeted["error"], budgeted)
                if scenario == "ok" and mode == "body":
                    before = len(ts.requests())
                    test.tool(server, "mail_get", {"uid": 2, "uidvalidity": 9, "section": "text"}, **env)
                    test.check("Jev capture observes ordinary text positive control", "VISIBLE_CONTROL" in
                               json.dumps(ts.requests()[before:]))
                    before = len(ts.requests())
                    code, off = test.tool(server, "mail_get", args(), **{**env, "MAILBEND_TYPESAFE": "0"})
                    test.check("nested Jev off has no annotation or request", code == 0 and off == result(expected) and
                               len(ts.requests()) == before, off)
            finally:
                ts.stop()
    finally:
        server.stop()


def with_budget(literal):
    literal = copy.deepcopy(literal)
    literal["response"] = {"projection": "full", "max_bytes": 1000,
        "budget_scope": "result_json_utf8", "output_truncated": False,
        "request_more": "Use projection=full and raise max_response_bytes; raise max_bytes if truncated=true. For lists, reduce limit and keep the same checkpoint.",
        "content_complete": True}
    for _ in range(3):
        literal["response"]["max_bytes"] = len(json.dumps(literal, ensure_ascii=False, separators=(",", ":")).encode())
    assert len(json.dumps(literal, ensure_ascii=False, separators=(",", ":")).encode()) == literal["response"]["max_bytes"]
    return literal


def response_budget(test, work):
    server = test.Server(work, fixture=fixture(test, [message(b"Subject: inner\r\n\r\nhello")]))
    try:
        literal = with_budget(result(node("inner", "hello")))
        size = literal["response"]["max_bytes"]
        code, actual = test.tool(server, "mail_get", args(max_response_bytes=size))
        test.check("nested exact serialized fit", code == 0 and actual == literal, actual)
        code, actual = test.tool(server, "mail_get", args(max_response_bytes=size - 1))
        test.check("nested one byte short is atomic", code != 0 and set(actual) == {"error"} and
                   "complete nested representation" in actual["error"], actual)
    finally:
        server.stop()


def run(test, work, resources=False):
    for mode in ("cli", "mcp"):
        os.environ["MAILBEND_TEST_MCP"] = "1" if mode == "mcp" else "0"
        public_reads(test, work)
        legacy_reads(test, work)
        annotations(test, work)
        response_budget(test, work)
        if resources:
            resource_reads(test, work)
