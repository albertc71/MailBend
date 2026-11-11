#!/usr/bin/env python3
"""Bounded synthetic CLI/MCP contract for Answered and Draft flag searches."""
import copy
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import tempfile
import time

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
MAX_CALLS = 100
OUTPUT_LIMIT = 2 * 1024 * 1024
DEADLINE_SECONDS = 300
ACTIVE = set()
CALLS = 0
MCP = os.environ.get("MAILBEND_TEST_MCP") == "1"
PASSWORD = "search-flags-synthetic-password"


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def stop(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)
    ACTIVE.discard(process)


def output_cap():
    resource.setrlimit(resource.RLIMIT_FSIZE, (OUTPUT_LIMIT, OUTPUT_LIMIT))


def run(command, env, data=None):
    global CALLS
    CALLS += 1
    require(CALLS <= MAX_CALLS, "synthetic process budget exceeded")
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=out, stderr=err,
                                   env=env, start_new_session=True, preexec_fn=output_cap)
        ACTIVE.add(process)
        try:
            process.communicate(data, timeout=30)
            out.seek(0)
            err.seek(0)
            stdout, stderr = out.read(OUTPUT_LIMIT + 1), err.read(OUTPUT_LIMIT + 1)
            require(len(stdout) < OUTPUT_LIMIT and len(stderr) < OUTPUT_LIMIT,
                    "synthetic output bound reached")
            require(PASSWORD.encode() not in stdout + stderr, "synthetic credential leaked")
            return process.returncode, stdout.decode(), stderr.decode()
        finally:
            stop(process)


def fixture():
    rows = [(1, [], "needle", "15-Feb-2026"),
            (2, ["\\Answered", "\\Seen"], "needle", "15-Feb-2026"),
            (3, ["\\Draft"], "needle", "15-Feb-2026"),
            (4, ["\\Answered", "\\Draft", "\\Flagged"], "needle", "15-Feb-2026"),
            (5, [], "other", "15-Feb-2026"),
            (6, ["\\Answered", "\\Draft"], "needle", "15-Jan-2026")]
    messages = [{"uid": uid, "flags": flags, "internaldate": date + " 09:00:00 +0000",
                 "raw": f"From: alice@example.test\r\nTo: tester@example.test\r\n"
                        f"Message-ID: <flag-{uid}@example.test>\r\nSubject: {subject}\r\n"
                        "Content-Type: text/plain; charset=utf-8\r\n\r\n"
                        + "x" * 4000 + '\r\nCafé "quoted" text\r\n'}
                for uid, flags, subject, date in rows]
    return {"user": "tester@example.test", "password": PASSWORD,
            "mailboxes": {"INBOX": {"uidvalidity": 7, "special": [], "messages": messages},
                          "Drafts": {"uidvalidity": 8, "special": ["\\Drafts"], "messages": []}}}


class Server:
    def __init__(self, work):
        self.work = work
        self.validator = None
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("MAILBEND_") and k not in {"SSL_CERT_FILE", "SSL_CERT_DIR"}}
        self.env.update(MAILBEND_EMAIL="tester@example.test", MAILBEND_APP_PASSWORD=PASSWORD,
                        MAILBEND_IMAP_HOST="localhost", MAILBEND_SMTP_HOST="localhost",
                        MAILBEND_CA_FILE=str(work / "certs/ca.pem"), MAILBEND_TIMEOUT_MS="10000")
        code, _, _ = run(["sh", str(ROOT / "tests/gen-test-certs.sh"), str(work / "certs"), "--demo"], self.env)
        require(code == 0, "synthetic certificate setup failed")
        (work / "fixture.json").write_text(json.dumps(fixture()))
        self.out = open(work / "server.out", "w+b")
        self.err = open(work / "server.err", "w+b")
        self.process = subprocess.Popen(
            ["python3", str(ROOT / "tests/fake_mail_server.py"), "--certdir", str(work / "certs"),
             "--fixture", str(work / "fixture.json"), "--state", str(work / "state.json"),
             "--log", str(work / "log.jsonl")], stdout=self.out, stderr=self.err,
            env=self.env, start_new_session=True, preexec_fn=output_cap)
        ACTIVE.add(self.process)
        until = time.monotonic() + 10
        while time.monotonic() < until:
            self.out.seek(0)
            line = self.out.readline(4096).decode()
            if line.startswith("READY "):
                ports = dict(item.split("=") for item in line.split()[1:])
                self.env.update(MAILBEND_IMAP_PORT=ports["imap"], MAILBEND_SMTP_PORT=ports["smtp"])
                return
            require(self.process.poll() is None, "synthetic server exited before READY")
            time.sleep(0.02)
        raise AssertionError("synthetic server startup exceeded 10 seconds")

    def lines(self):
        path = self.work / "log.jsonl"
        return [json.loads(line)["line"] for line in path.read_text().splitlines()] if path.exists() else []

    def state(self):
        return json.loads((self.work / "state.json").read_text())

    def mcp(self, requests, **settings):
        code, out, err = run([str(ROOT / "scripts/mailbend"), "mcp"], {**self.env, **settings},
                             ("\n".join(requests) + "\n").encode())
        require(code == 0, ("MCP process failed", code, err))
        return [json.loads(line) for line in out.splitlines() if line]

    def call(self, args, **settings):
        raw = args if isinstance(args, str) else json.dumps(args)
        if MCP:
            replies = self.mcp([json.dumps({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                                           "params": {"protocolVersion": "2025-06-18"}}),
                                '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":'
                                '{"name":"mail_search","arguments":' + raw + '}}'], **settings)
            result = replies[-1]["result"]
            value = json.loads(result["content"][0]["text"])
            require(result.get("structuredContent") == value, "MCP structured/text disagreement")
            require(type(result.get("isError")) is bool, "MCP missing error indicator")
            self.validator.validate(value)
            return int(result["isError"]), value
        code, out, err = run([str(ROOT / "scripts/mailbend"), "call", "mail_search", raw],
                             {**self.env, **settings})
        require(code in (0, 1), ("CLI process failed", code, err))
        value = json.loads(out)
        self.validator.validate(value)
        return code, value


def modern(method, **params):
    return json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": {
        "_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                  "io.modelcontextprotocol/clientCapabilities": {}}, **params}})


def discovery(server):
    start = len(server.lines())
    code, out, _ = run([str(ROOT / "scripts/mailbend"), "tools", "mail_search"], server.env)
    require(code == 0, "CLI discovery failed")
    definitions = [json.loads(out)]
    for requests in ([json.dumps({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                                 "params": {"protocolVersion": "2025-06-18"}}),
                      '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'],
                     [modern("tools/list")]):
        listed = server.mcp(requests)[-1]["result"]["tools"]
        definitions.append(next(tool for tool in listed if tool["name"] == "mail_search"))
    for definition in definitions:
        schema = definition["inputSchema"]
        for field in ("answered", "draft"):
            require(schema["properties"][field]["type"] == "boolean", (field, schema))
            require(field not in schema.get("required", []) and "default" not in schema["properties"][field],
                    "flags must remain optional without defaults")
        require(definition["annotations"] == {"readOnlyHint": True, "destructiveHint": False,
                                             "idempotentHint": True, "openWorldHint": True},
                "search annotations changed")
    require(all(d["inputSchema"] == definitions[0]["inputSchema"] for d in definitions),
            "discovery surfaces disagree")
    Draft202012Validator.check_schema(definitions[1]["outputSchema"])
    server.validator = Draft202012Validator(definitions[1]["outputSchema"])
    require(len(server.lines()) == start, "discovery contacted mail server")
    result = server.mcp([modern("tools/call", name="mail_search",
                                arguments={"answered": False, "draft": True})])[-1]["result"]
    value = json.loads(result["content"][0]["text"])
    server.validator.validate(value)
    require(result["structuredContent"] == value and not result["isError"], "modern structured call failed")
    require([m["uid"] for m in value["messages"]] == [3], "modern flag truth table failed")


def check_query(server, args, expected, wire, **settings):
    start = len(server.lines())
    code, value = server.call(args, **settings)
    require(code == 0 and [m["uid"] for m in value.get("messages", [])] == expected,
            ("wrong matching UIDs", args, value))
    require(value["total"] == len(expected), ("wrong full-query total", value))
    searches = [line.split(" UID SEARCH ", 1)[1] for line in server.lines()[start:] if " UID SEARCH " in line]
    require(searches == [wire], ("wrong exact search bytes", searches, wire))
    require(all("draft" not in message for message in value["messages"]), "unexpected output field")


def refused(server, raw, phrase):
    start = len(server.lines())
    code, value = server.call(raw)
    require(code != 0 and phrase in value.get("error", ""), ("wrong refusal", raw, value))
    require(len(server.lines()) == start, "invalid arguments reached network")


def scenarios(server):
    before = copy.deepcopy(server.state())
    discovery(server)
    cases = [({}, [6, 5, 4, 3, 2, 1], "ALL"),
             ({"draft": True}, [6, 4, 3], "DRAFT"),
             ({"draft": False}, [5, 2, 1], "UNDRAFT"),
             ({"answered": True}, [6, 4, 2], "ANSWERED"),
             ({"answered": True, "draft": True}, [6, 4], "ANSWERED DRAFT"),
             ({"answered": True, "draft": False}, [2], "ANSWERED UNDRAFT"),
             ({"answered": False}, [5, 3, 1], "UNANSWERED"),
             ({"answered": False, "draft": True}, [3], "UNANSWERED DRAFT"),
             ({"answered": False, "draft": False}, [5, 1], "UNANSWERED UNDRAFT")]
    for args, expected, wire in cases:
        check_query(server, args, expected, wire)
    check_query(server, {"subject": "needle", "since": "2026-02-01", "before": "2026-03-01",
                         "seen": False, "flagged": True, "answered": True, "draft": True}, [4],
                'SUBJECT "needle" UNSEEN FLAGGED ANSWERED DRAFT SINCE 1-Feb-2026 BEFORE 1-Mar-2026')
    check_query(server, {"draft": True, "projection": "metadata"}, [6, 4, 3], "DRAFT")
    for setting in ("MAILBEND_READ_ONLY", "MAILBEND_DRAFTS_ONLY"):
        check_query(server, {"answered": False, "draft": True}, [3], "UNANSWERED DRAFT", **{setting: "1"})
    for field in ("answered", "draft"):
        for value in ("null", '"false"', "1", "[]", "{}"):
            refused(server, '{"' + field + '":' + value + '}', "must be true or false")
        refused(server, '{"' + field + '":true,"' + field + '":false}', "is given more than once")
        for selected, expected in ((True, [6, 4, 2] if field == "answered" else [6, 4, 3]),
                                   (False, [5, 3, 1] if field == "answered" else [5, 2, 1])):
            code, first = server.call({field: selected, "limit": 1})
            require(code == 0 and [m["uid"] for m in first["messages"]] == expected[:1], first)
            cursor = first["next_cursor"]
            code, last = server.call({"limit": 2, "cursor": cursor, field: selected})
            require(code == 0 and [m["uid"] for m in last["messages"]] == expected[1:]
                    and last["total"] == 3 and last["has_more"] is False and last["next_cursor"] is None, last)
            refused(server, {"cursor": cursor, field: not selected}, "cursor")
            refused(server, {"cursor": cursor}, "cursor")
    for alias in ("unanswered", "undraft"):
        refused(server, {alias: True}, "unknown")
    code, old = server.call({"limit": 1})
    require(code == 0 and old["next_cursor"] == 's1:7:6:["INBOX","ALL"]', "legacy cursor bytes changed")
    code, page = server.call({"cursor": 's1:7:6:["INBOX","ALL"]', "limit": 200})
    require(code == 0 and [m["uid"] for m in page["messages"]] == [5, 4, 3, 2, 1], page)
    for field in ("answered", "draft"):
        for selected in (True, False):
            refused(server, {field: selected, "cursor": old["next_cursor"]}, "cursor")
    for limit, expected in ((0, [6]), (201, [6, 4, 2])):
        code, value = server.call({"answered": True, "limit": limit})
        require(code == 0 and [m["uid"] for m in value["messages"]] == expected
                and value["total"] == 3, ("legacy limit clamp changed", value))
    refused(server, {"answered": True, "cursor": "x" * 4097}, "cursor")
    text = "x" * 3979
    binding = json.dumps(["INBOX", 'TEXT "' + text + '"'], separators=(",", ":"))
    require(len(binding) == 4000, "boundary fixture is not exactly 4000 characters")
    code, fits = server.call({"text": text, "limit": 1})
    require(code == 0 and isinstance(fits["next_cursor"], str), "legacy fitting query lost pagination")
    code, over = server.call({"text": text, "answered": True, "limit": 1})
    require(code == 0 and over["total"] == 3 and over["has_more"] is True
            and over["next_cursor"] is None and "4000-character" in over.get("pagination_unavailable", ""), over)
    refused(server, {"text": text, "answered": True, "cursor": fits["next_cursor"]}, "cursor")
    lines = server.lines()
    require(any(' EXAMINE "INBOX"' in line for line in lines), "missing positive EXAMINE evidence")
    fetches = [line for line in lines if " UID FETCH " in line]
    require(fetches and all("BODY.PEEK[" in line for line in fetches), "missing positive BODY.PEEK evidence")
    require(not any(any(atom in line for atom in (" SELECT ", " STORE ", " APPEND ", " EXPUNGE", " COPY ", " MOVE ",
                                                               " CREATE ", " RENAME ", " SUBSCRIBE ", " UNSUBSCRIBE ", " MAIL FROM"))
                    for line in lines), "search emitted a mutating command")
    require(all(" UID SEARCH " in line for line in lines if " SEARCH " in line),
            "search used a sequence-number command")
    require(server.state() == before, "search changed fixture state or flags")


def expired(signum, frame):
    raise TimeoutError("search flag suite exceeded 300 seconds")


def main():
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(DEADLINE_SECONDS)
    try:
        with tempfile.TemporaryDirectory(prefix="mailbend-search-flags-") as directory:
            server = Server(Path(directory))
            try:
                scenarios(server)
            finally:
                stop(server.process)
                server.out.close()
                server.err.close()
        print(f"PASS structured search flags ({'MCP' if MCP else 'CLI'}), {CALLS} bounded processes")
    finally:
        signal.alarm(0)
        for process in list(ACTIVE):
            stop(process)


if __name__ == "__main__":
    main()
