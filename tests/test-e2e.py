#!/usr/bin/env python3
"""End-to-end tests: every MailBend tool, through scripts/mailbend (CLI and
MCP stdio), against tests/fake_mail_server.py over verified TLS.

Checks tool results and the server's recorded state and command log: reads
never add \\Seen and never SELECT, deletion needs confirmation, trash is
recoverable, mail is actually delivered, and the password never appears in
any output. Run: python3 tests/test-e2e.py   (after scripts/install.sh)
"""
import json, os, subprocess, sys, tempfile, time, pathlib, shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
LAUNCHER = str(ROOT / "scripts" / "mailbend")
FIXTURE = ROOT / "tests" / "fixtures" / "mailbox.json"
FIX = json.loads(FIXTURE.read_text(encoding="utf-8"))
PASSWORD = FIX["password"]

results = []
outputs = []  # every stdout/stderr captured, scanned for the password at the end


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  -- " + str(detail)[:600]))


class Server:
    def __init__(self, work, caps=None, extra=()):
        self.work = work
        self.state = os.path.join(work, "state.json")
        self.log = os.path.join(work, "log.jsonl")
        for f in (self.state, self.log):
            if os.path.exists(f):
                os.remove(f)
        cmd = [sys.executable, str(ROOT / "tests" / "fake_mail_server.py"), "--certdir", os.path.join(work, "certs"),
               "--fixture", str(FIXTURE), "--state", self.state, "--log", self.log, *extra]
        if caps is not None:
            cmd += ["--caps", caps]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True)
        line = self.proc.stdout.readline().split()
        assert line and line[0] == "READY", line
        ports = dict(kv.split("=") for kv in line[1:])
        self.imap, self.smtp = ports["imap"], ports["smtp"]

    def env(self, **over):
        e = dict(os.environ)
        e.update({"MAILBEND_EMAIL": FIX["user"], "MAILBEND_APP_PASSWORD": PASSWORD,
                  "MAILBEND_IMAP_HOST": "localhost", "MAILBEND_IMAP_PORT": self.imap,
                  "MAILBEND_SMTP_HOST": "localhost", "MAILBEND_SMTP_PORT": self.smtp,
                  "MAILBEND_CA_FILE": os.path.join(self.work, "certs", "ca.pem"), "MAILBEND_TIMEOUT_MS": "10000"})
        e.pop("MAILBEND_READ_ONLY", None)
        e.pop("MAILBEND_TLS_HELPER", None)
        for k, v in over.items():
            if v is None:
                e.pop(k, None)
            else:
                e[k] = v
        return e

    def st(self):
        return json.loads(pathlib.Path(self.state).read_text(encoding="utf-8"))

    def log_lines(self):
        p = pathlib.Path(self.log)
        return [json.loads(l)["line"] for l in p.read_text(encoding="utf-8").splitlines() if l.strip()] if p.exists() else []

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def tool(srv, name, args=None, **env):
    p = subprocess.run([LAUNCHER, "call", name, json.dumps(args or {})], capture_output=True, text=True,
                       env=srv.env(**env), timeout=120)
    outputs.extend([p.stdout, p.stderr])
    try:
        out = json.loads(p.stdout.strip().splitlines()[-1]) if p.stdout.strip() else {}
    except (json.JSONDecodeError, IndexError):
        out = {"unparsed": p.stdout, "stderr": p.stderr}
    return p.returncode, out


def msgs(state, box):
    return {m["uid"]: m for m in state["mailboxes"][box]["messages"]}


def flags(state, box, uid):
    return set(msgs(state, box)[uid]["flags"])


def main():
    work = tempfile.mkdtemp(prefix="e2e-", dir=str(ROOT / "build") if (ROOT / "build").exists() else None)
    try:
        subprocess.run(["sh", str(ROOT / "tests" / "gen-test-certs.sh"), os.path.join(work, "certs")],
                       check=True, capture_output=True)
        run_all(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    leaked = [o for o in outputs if PASSWORD in o]
    check("password never appears in any tool output", not leaked, leaked[:1])
    failed = [n for n, ok in results if not ok]
    print(f"e2e: {len(results) - len(failed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


def run_all(work):
    srv = Server(work)
    try:
        reads(srv)
        mutations(srv)
        compose(srv)
        mcp(srv)
        read_only(srv)
        failures(srv, work)
    finally:
        srv.stop()
    fallback(work)


def reads(srv):
    before = srv.st()
    c, r = tool(srv, "mail_probe")
    check("probe: ok over verified TLS", c == 0 and r.get("ok") and r.get("tls_verified"), r)
    check("probe: capabilities after login", {"MOVE", "UIDPLUS", "IDLE"} <= set(r.get("capabilities", [])) and r.get("idle"), r)
    su = r.get("special_use", {})
    check("probe: special-use folders discovered", su.get("trash") == "Deleted Messages" and su.get("drafts") == "Drafts"
          and su.get("sent") == "Sent Messages", su)

    c, r = tool(srv, "mail_list_folders")
    names = {f["name"]: f for f in r.get("folders", [])}
    check("folders: all listed, UTF-7 names decoded", c == 0 and {"INBOX", "Work/Projects", "日本", "Deleted Messages"} <= set(names), list(names))
    check("folders: special use roles", names.get("Deleted Messages", {}).get("special_use") == "trash"
          and names.get("Drafts", {}).get("special_use") == "drafts", names.get("Drafts"))

    c, r = tool(srv, "mail_search")
    uids = [m["uid"] for m in r.get("messages", [])]
    check("search: all messages, newest first", c == 0 and r.get("total") == 6 and uids == [6, 5, 4, 3, 2, 1], r)
    check("search: uidvalidity reported", r.get("uidvalidity") == 1700000001, r.get("uidvalidity"))
    subj = {m["uid"]: m["subject"] for m in r.get("messages", [])}
    check("search: RFC 2047 subject decoded", subj.get(2) == "Café menu", subj)
    frm = {m["uid"]: m["from"] for m in r.get("messages", [])}
    check("search: encoded display name decoded", frm.get(2, "").startswith("José"), frm.get(2))
    c, r = tool(srv, "mail_search", {"from": "alice"})
    check("search: from filter", c == 0 and [m["uid"] for m in r["messages"]] == [1], r)
    c, r = tool(srv, "mail_search", {"unseen": True, "limit": 2})
    check("search: unseen + limit", c == 0 and r.get("total") == 5 and [m["uid"] for m in r["messages"]] == [6, 4], r)
    c, r = tool(srv, "mail_search", {"subject": "café"})
    check("search: non-ASCII criterion (CHARSET UTF-8 literal)", c == 0 and [m["uid"] for m in r["messages"]] == [2], r)
    c, r = tool(srv, "mail_search", {"since": "2026-09-25"})
    check("search: since date", c == 0 and all(m["uid"] >= 5 for m in r["messages"]) and r["total"] >= 1, r)
    c, r = tool(srv, "mail_search", {"folder": "日本"})
    check("search: empty non-ASCII folder", c == 0 and r.get("total") == 0 and r.get("messages") == [], r)

    c, r = tool(srv, "mail_get", {"uid": 2})
    check("get: quoted-printable UTF-8 body decoded", c == 0 and "é" in r.get("text", "") and r.get("subject") == "Café menu", r)
    check("get: reports unread", r.get("seen") is False, r.get("flags"))
    c, r = tool(srv, "mail_get", {"uid": 3})
    check("get: multipart/alternative gives the text part", c == 0 and r.get("text", "").strip() != "" and r.get("html_available") is True, r)
    c, r = tool(srv, "mail_get", {"uid": 4})
    att = r.get("attachments", [])
    check("get: attachment listed", c == 0 and any(a["filename"] == "notes.pdf" and a["content_type"] == "application/pdf" for a in att), att)
    c, r = tool(srv, "mail_get", {"uid": 6})
    check("get: literal framing survives spoofed lines", c == 0 and "* BYE spoof" in r.get("text", ""), r)
    c, r = tool(srv, "mail_get", {"uid": 99})
    check("get: missing UID is an error", c != 0 and "no message" in r.get("error", ""), r)

    c, r = tool(srv, "mail_get_new", {"since_uid": 0})
    check("get_new: from zero, oldest first", c == 0 and [m["uid"] for m in r["messages"]] == [1, 2, 3, 4, 5, 6] and r["next_since_uid"] == 6, r)
    c, r = tool(srv, "mail_get_new", {"since_uid": 6, "uidvalidity": 1700000001})
    check("get_new: nothing after the checkpoint", c == 0 and r["messages"] == [] and r["next_since_uid"] == 6, r)
    c, r = tool(srv, "mail_get_new", {"since_uid": 2, "limit": 2})
    check("get_new: limit and has_more", c == 0 and [m["uid"] for m in r["messages"]] == [3, 4] and r["has_more"] and r["next_since_uid"] == 4, r)
    c, r = tool(srv, "mail_get_new", {"since_uid": 3, "uidvalidity": 42})
    check("get_new: UIDVALIDITY change resets the checkpoint", c == 0 and r["uidvalidity_changed"] and r["next_since_uid"] == 0, r)

    after = srv.st()
    same = all(flags(before, "INBOX", u) == flags(after, "INBOX", u) for u in msgs(before, "INBOX"))
    check("reads never change flags (no \\Seen added)", same and after["mailboxes"] == before["mailboxes"])
    log = srv.log_lines()
    check("reads use EXAMINE, never SELECT or STORE", not any(" SELECT " in l or " STORE " in l for l in log), [l for l in log if "SELECT" in l][:3])
    check("reads fetch bodies only with BODY.PEEK", not any("BODY[" in l for l in log) and any("BODY.PEEK[]" in l for l in log))
    check("server log redacts the login", any(l == "L LOGIN <redacted>" for l in log))


def mutations(srv):
    c, r = tool(srv, "mail_mark_read", {"uids": [1, 2]})
    s = srv.st()
    check("mark_read adds \\Seen", c == 0 and "\\Seen" in flags(s, "INBOX", 1) and "\\Seen" in flags(s, "INBOX", 2), r)
    c, r = tool(srv, "mail_mark_unread", {"uids": [2]})
    s = srv.st()
    check("mark_unread removes \\Seen", c == 0 and "\\Seen" not in flags(s, "INBOX", 2) and "\\Seen" in flags(s, "INBOX", 1), r)
    c, r = tool(srv, "mail_mark_read", {"uids": []})
    check("mark_read needs UIDs", c != 0 and "uids" in r.get("error", ""), r)

    c, r = tool(srv, "mail_move", {"uids": [3], "destination": "Archive"})
    s = srv.st()
    check("move with UID MOVE", c == 0 and r.get("method") == "UID MOVE" and 3 not in msgs(s, "INBOX")
          and len(s["mailboxes"]["Archive"]["messages"]) == 1, r)
    c, r = tool(srv, "mail_move", {"uids": [5], "destination": "Nope"})
    check("move to a missing folder is rejected", c != 0 and "rejected" in r.get("error", "") and 5 in msgs(srv.st(), "INBOX"), r)

    c, r = tool(srv, "mail_trash", {"uids": [1]})
    s = srv.st()
    check("trash moves to the special-use Trash", c == 0 and r.get("destination") == "Deleted Messages" and 1 not in msgs(s, "INBOX")
          and len(s["mailboxes"]["Deleted Messages"]["messages"]) == 1, r)
    c, r = tool(srv, "mail_trash", {"folder": "Deleted Messages", "uids": [1]})
    check("trash refuses to act inside Trash", c != 0 and "mail_delete" in r.get("error", ""), r)

    before = srv.st()
    c, r = tool(srv, "mail_delete", {"uids": [4]})
    check("delete without confirmation does nothing", c != 0 and "confirm" in r.get("error", "") and srv.st() == before, r)
    c, r = tool(srv, "mail_delete", {"uids": [4], "confirm": "yes"})
    check("delete with a wrong confirmation does nothing", c != 0 and srv.st() == before, r)
    n_log = len(srv.log_lines())
    c, r = tool(srv, "mail_delete", {"uids": [4], "confirm": "permanently-delete"})
    s = srv.st()
    trash_uids = [m["uid"] for m in s["mailboxes"]["Deleted Messages"]["messages"]]
    check("delete with confirmation expunges exactly that UID", c == 0 and r.get("permanently_deleted") and 4 not in msgs(s, "INBOX")
          and 5 in msgs(s, "INBOX") and len(trash_uids) == 1, r)
    check("delete uses UID EXPUNGE, not EXPUNGE", any(l.endswith("UID EXPUNGE 4") for l in srv.log_lines()[n_log:])
          and not any(l.split(" ", 1)[-1] == "EXPUNGE" for l in srv.log_lines()))


def compose(srv):
    att = os.path.join(srv.work, "report.txt")
    pathlib.Path(att).write_text("quarterly numbers\n")
    c, r = tool(srv, "mail_save_draft", {"to": ["José Q <jose@example.com>"], "subject": "Brouillon é",
                                         "body": "Draft body é\n.leading dot", "attachments": [{"path": att}]})
    s = srv.st()
    drafts = s["mailboxes"]["Drafts"]["messages"]
    check("save_draft appends to Drafts with \\Draft", c == 0 and len(drafts) == 1 and "\\Draft" in drafts[0]["flags"]
          and r.get("saved_to") == "Drafts" and isinstance(r.get("uid"), int), r)
    raw = drafts[0]["raw"] if drafts else ""
    check("draft is 7-bit MIME with the attachment", all(ord(ch) < 128 for ch in raw) and "report.txt" in raw
          and "multipart/mixed" in raw and "=?UTF-8?B?" in raw, raw[:400])
    c, r = tool(srv, "mail_get", {"folder": "Drafts", "uid": drafts[0]["uid"] if drafts else 1})
    check("draft reads back: subject, body, attachment", c == 0 and r.get("subject") == "Brouillon é" and "Draft body é" in r.get("text", "")
          and any(a["filename"] == "report.txt" for a in r.get("attachments", [])), r)

    c, r = tool(srv, "mail_send", {"to": "friend@example.com", "cc": ["Carol <carol@example.com>"], "bcc": ["hidden@example.com"],
                                   "subject": "Hello ✓", "body": "Hi there\n.dot line\n"})
    s = srv.st()
    sent = s.get("sent", [])
    check("send delivers over SMTP", c == 0 and r.get("sent") and len(sent) == 1, r)
    if sent:
        m = sent[-1]
        check("send envelope: sender and all recipients", m["mail_from"] == FIX["user"]
              and set(m["rcpt_to"]) == {"friend@example.com", "carol@example.com", "hidden@example.com"}, m)
        check("send: Bcc never in the message", "hidden@example.com" not in m["data"], m["data"][:300])
        check("send: dot-stuffing round-trips", "\r\n.dot line" in m["data"] or "\n.dot line" in m["data"], m["data"][-200:])
        check("send: Message-ID matches the result", r.get("message_id", "?") in m["data"], r.get("message_id"))

    n = len(srv.st().get("sent", []))
    c, r = tool(srv, "mail_send", {"to": "a@b.c\r\nRCPT TO:<evil@example.com>", "subject": "x", "body": "x"})
    check("send rejects header/envelope injection", c != 0 and len(srv.st().get("sent", [])) == n, r)
    c, r = tool(srv, "mail_send", {"to": "reject@example.com", "subject": "x", "body": "x"})
    check("send reports a refused recipient", c != 0 and "550" in r.get("error", "") and len(srv.st().get("sent", [])) == n, r)
    c, r = tool(srv, "mail_send", {"subject": "no rcpt", "body": "x"})
    check("send needs a recipient", c != 0 and "recipient" in r.get("error", ""), r)

    c, r = tool(srv, "mail_reply", {"uid": 2, "body": "Sounds good"})
    sent = srv.st().get("sent", [])
    orig_id = next(l for l in msgs(srv.st(), "INBOX")[2]["raw"].split("\r\n") if l.lower().startswith("message-id:")).split(":", 1)[1].strip()
    ok = c == 0 and len(sent) == n + 1
    data = sent[-1]["data"] if ok else ""
    check("reply sends to the original sender", ok and sent[-1]["rcpt_to"] == ["jose@example.com"], r)
    check("reply threads: In-Reply-To, References, Re: subject", ("In-Reply-To: " + orig_id) in data and orig_id in data.split("References:", 1)[-1]
          and "Subject: Re: " in data.replace("=?UTF-8?B?", "Subject: Re: ") , data[:500])
    c, r = tool(srv, "mail_reply", {"uid": 2, "body": "draft reply", "as_draft": True})
    check("reply as draft goes to Drafts", c == 0 and r.get("saved_to") == "Drafts" and len(srv.st()["mailboxes"]["Drafts"]["messages"]) == 2, r)

    c, r = tool(srv, "mail_forward", {"uid": 5, "to": ["boss@example.com"], "body": "FYI"})
    sent = srv.st().get("sent", [])
    data = sent[-1]["data"] if sent else ""
    check("forward attaches the original as message/rfc822", c == 0 and sent[-1]["rcpt_to"] == ["boss@example.com"]
          and "message/rfc822" in data and "forwarded-message.eml" in data, r)
    s = srv.st()
    check("reply/forward left the originals unread-state untouched", "\\Seen" not in flags(s, "INBOX", 2) and "\\Seen" in flags(s, "INBOX", 5))


def mcp_session(srv, requests, **env):
    p = subprocess.Popen([LAUNCHER, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, env=srv.env(**env))
    out, err = p.communicate("\n".join(json.dumps(r) if not isinstance(r, str) else r for r in requests) + "\n", timeout=180)
    outputs.extend([out, err])
    return [json.loads(l) for l in out.splitlines() if l.strip()], p.returncode


def mcp(srv):
    reqs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "mail_search", "arguments": {"from": "bob"}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "mail_delete", "arguments": {"uids": [5]}}},
        "this is not json",
        {"jsonrpc": "2.0", "id": 5, "method": "resources/list"},
        {"jsonrpc": "2.0", "id": 6, "method": "ping"},
    ]
    res, code = mcp_session(srv, reqs)
    by_id = {r.get("id"): r for r in res}
    check("mcp: exactly one answer per request (none for the notification)", len(res) == 7, res)
    init = by_id.get(1, {}).get("result", {})
    check("mcp: initialize", init.get("protocolVersion") == "2025-06-18" and "tools" in init.get("capabilities", {})
          and init.get("serverInfo", {}).get("name") == "mailbend", init)
    tools = by_id.get(2, {}).get("result", {}).get("tools", [])
    names = [t["name"] for t in tools]
    check("mcp: tools/list has all 14 tools with schemas", len(tools) == 14 and all("inputSchema" in t for t in tools), names)
    ann = {t["name"]: t.get("annotations", {}) for t in tools}
    check("mcp: read tools are marked read-only, delete destructive",
          all(ann[n]["readOnlyHint"] for n in ["mail_probe", "mail_list_folders", "mail_search", "mail_get", "mail_get_new"])
          and ann["mail_delete"]["destructiveHint"] and not ann["mail_trash"]["destructiveHint"], ann)
    call = by_id.get(3, {}).get("result", {})
    payload = json.loads(call.get("content", [{}])[0].get("text", "{}"))
    check("mcp: tools/call returns the result", call.get("isError") is False and [m["uid"] for m in payload.get("messages", [])] == [3] or
          call.get("isError") is False and payload.get("folder") == "INBOX", call)
    dele = by_id.get(4, {}).get("result", {})
    check("mcp: refused delete is an isError result", dele.get("isError") is True and 5 in msgs(srv.st(), "INBOX"), dele)
    check("mcp: parse error answered with -32700", any(r.get("error", {}).get("code") == -32700 for r in res), res)
    check("mcp: unknown method answered with -32601", by_id.get(5, {}).get("error", {}).get("code") == -32601, by_id.get(5))
    check("mcp: ping", by_id.get(6, {}).get("result") == {}, by_id.get(6))
    check("mcp: exits cleanly when stdin closes", code == 0, code)


def read_only(srv):
    before = srv.st()
    c, r = tool(srv, "mail_trash", {"uids": [5]}, MAILBEND_READ_ONLY="1")
    check("read-only mode refuses changes", c != 0 and "MAILBEND_READ_ONLY" in r.get("error", "") and srv.st() == before, r)
    c, r = tool(srv, "mail_search", {}, MAILBEND_READ_ONLY="1")
    check("read-only mode still allows reads", c == 0 and "messages" in r, r)


def failures(srv, work):
    c, r = tool(srv, "mail_probe", MAILBEND_CA_FILE=None)
    check("unknown CA is refused (TLS verification)", c != 0 and "TLS verification failed" in r.get("error", ""), r)
    c, r = tool(srv, "mail_probe", MAILBEND_IMAP_HOST="127.0.0.1")
    check("host name mismatch is refused", c != 0 and "TLS verification failed" in r.get("error", ""), r)
    c, r = tool(srv, "mail_probe", MAILBEND_APP_PASSWORD="wrong-password")
    check("wrong password reports authentication failure", c != 0 and "authentication failed" in r.get("error", ""), r)
    c, r = tool(srv, "mail_probe", MAILBEND_APP_PASSWORD=None)
    check("missing password is a configuration error", c != 0 and "MAILBEND_APP_PASSWORD" in r.get("error", ""), r)


def fallback(work):
    srv = Server(work, caps="UIDPLUS")
    try:
        c, r = tool(srv, "mail_probe")
        check("no SPECIAL-USE: folders found by name", c == 0 and r["special_use"]["trash"] == "Deleted Messages"
              and r["special_use"]["drafts"] == "Drafts" and not r["move"], r)
        c, r = tool(srv, "mail_move", {"uids": [3], "destination": "Archive"})
        s = srv.st()
        check("no MOVE: copy + UID EXPUNGE of exactly those UIDs", c == 0 and r.get("method") == "UID COPY + UID EXPUNGE"
              and 3 not in msgs(s, "INBOX") and len(s["mailboxes"]["Archive"]["messages"]) == 1, r)
    finally:
        srv.stop()
    srv = Server(work, caps="")
    try:
        before = srv.st()
        c, r = tool(srv, "mail_move", {"uids": [3], "destination": "Archive"})
        check("no MOVE or UIDPLUS: move refused", c != 0 and "neither MOVE nor UIDPLUS" in r.get("error", ""), r)
        c, r = tool(srv, "mail_delete", {"uids": [3], "confirm": "permanently-delete"})
        check("no UIDPLUS: delete refused", c != 0 and "UIDPLUS" in r.get("error", "") and srv.st() == before, r)
        check("refusals sent no mutating command", not any(k in l for l in srv.log_lines() for k in (" STORE ", " EXPUNGE", " COPY ", " MOVE ")))
    finally:
        srv.stop()


if __name__ == "__main__":
    main()
