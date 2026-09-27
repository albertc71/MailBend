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
        e.pop("MAILBEND_ATTACH_DIR", None)
        e.pop("MAILBEND_TLS_HELPER", None)
        e.pop("MAILBEND_ATTACH_HELPER", None)
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
    c, r = tool(srv, "mail_get_new", {"since_uid": 2})
    check("get_new: a checkpoint UID needs its UIDVALIDITY", c != 0 and "uidvalidity" in r.get("error", ""), r)
    c, r = tool(srv, "mail_get_new", {"since_uid": 2, "uidvalidity": 1700000001, "limit": 2})
    check("get_new: limit and has_more", c == 0 and [m["uid"] for m in r["messages"]] == [3, 4] and r["has_more"] and r["next_since_uid"] == 4, r)
    c, r = tool(srv, "mail_get_new", {"since_uid": 4294967295, "uidvalidity": 1700000001})
    check("get_new: a checkpoint at the largest UID is empty, not a server error", c == 0 and r["messages"] == []
          and r["next_since_uid"] == 4294967295 and not r["uidvalidity_changed"], r)
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
    V = 1700000001  # INBOX UIDVALIDITY in the fixture
    c, r = tool(srv, "mail_mark_read", {"uids": [1, 2]})
    check("mark_read requires the folder's UIDVALIDITY", c != 0 and "uidvalidity" in r.get("error", ""), r)
    c, r = tool(srv, "mail_mark_read", {"uids": [1, 2], "uidvalidity": V})
    s = srv.st()
    check("mark_read adds \\Seen", c == 0 and "\\Seen" in flags(s, "INBOX", 1) and "\\Seen" in flags(s, "INBOX", 2)
          and r.get("changed") == [1, 2] and r.get("missing") == [], r)
    c, r = tool(srv, "mail_mark_unread", {"uids": [2], "uidvalidity": V})
    s = srv.st()
    check("mark_unread removes \\Seen", c == 0 and "\\Seen" not in flags(s, "INBOX", 2) and "\\Seen" in flags(s, "INBOX", 1), r)
    c, r = tool(srv, "mail_mark_read", {"uids": [], "uidvalidity": V})
    check("mark_read needs UIDs", c != 0 and "uids" in r.get("error", ""), r)
    c, r = tool(srv, "mail_mark_unread", {"uids": [1, 99], "uidvalidity": V})
    check("changes report UIDs that do not exist", c == 0 and r.get("changed") == [1] and r.get("missing") == [99], r)
    c, r = tool(srv, "mail_mark_unread", {"uids": [98, 99], "uidvalidity": V})
    check("a change on no existing UID is an error", c != 0 and "none of these UIDs" in r.get("error", ""), r)
    before = srv.st()
    n_log = len(srv.log_lines())
    c, r = tool(srv, "mail_mark_read", {"uids": [2], "uidvalidity": 42})
    new = srv.log_lines()[n_log:]
    check("stale UIDVALIDITY stops a change in the same session (after SELECT, before STORE)",
          c != 0 and "UIDVALIDITY" in r.get("error", "") and srv.st() == before
          and any(" SELECT " in l for l in new) and not any(" STORE " in l for l in new), (r, new))

    c, r = tool(srv, "mail_move", {"uids": [3], "destination": "Archive", "uidvalidity": V})
    s = srv.st()
    check("move with UID MOVE", c == 0 and r.get("method") == "UID MOVE" and 3 not in msgs(s, "INBOX")
          and len(s["mailboxes"]["Archive"]["messages"]) == 1, r)
    c, r = tool(srv, "mail_move", {"uids": [5], "destination": "inbox", "uidvalidity": V})
    check("INBOX is case-insensitive: no self-move", c != 0 and "different folder" in r.get("error", ""), r)
    c, r = tool(srv, "mail_move", {"uids": [5], "destination": "Nope", "uidvalidity": V})
    check("move to a missing folder is rejected", c != 0 and "rejected" in r.get("error", "") and 5 in msgs(srv.st(), "INBOX"), r)

    c, r = tool(srv, "mail_trash", {"uids": [1], "uidvalidity": V})
    s = srv.st()
    check("trash moves to the special-use Trash", c == 0 and r.get("destination") == "Deleted Messages" and 1 not in msgs(s, "INBOX")
          and len(s["mailboxes"]["Deleted Messages"]["messages"]) == 1, r)
    c, r = tool(srv, "mail_trash", {"folder": "Deleted Messages", "uids": [1], "uidvalidity": 1700000003})
    check("trash refuses to act inside Trash", c != 0 and "mail_delete" in r.get("error", ""), r)

    before = srv.st()
    c, r = tool(srv, "mail_move", {"uids": [5], "destination": "Archive", "uidvalidity": 42})
    check("stale UIDVALIDITY refuses a move", c != 0 and "UIDVALIDITY" in r.get("error", "") and srv.st() == before, r)
    c, r = tool(srv, "mail_delete", {"uids": [4], "confirm": "permanently-delete"})
    check("delete requires the folder's UIDVALIDITY", c != 0 and "uidvalidity" in r.get("error", "") and srv.st() == before, r)
    c, r = tool(srv, "mail_delete", {"uids": [4], "confirm": "permanently-delete", "uidvalidity": 42})
    check("delete with a stale UIDVALIDITY does nothing", c != 0 and "UIDVALIDITY" in r.get("error", "") and srv.st() == before, r)
    c, r = tool(srv, "mail_delete", {"uids": [4], "uidvalidity": 1700000001})
    check("delete without confirmation does nothing", c != 0 and "confirm" in r.get("error", "") and srv.st() == before, r)
    c, r = tool(srv, "mail_delete", {"uids": [4], "confirm": "yes", "uidvalidity": 1700000001})
    check("delete with a wrong confirmation does nothing", c != 0 and srv.st() == before, r)
    n_log = len(srv.log_lines())
    c, r = tool(srv, "mail_delete", {"uids": [4], "confirm": "permanently-delete", "uidvalidity": 1700000001})
    s = srv.st()
    trash_uids = [m["uid"] for m in s["mailboxes"]["Deleted Messages"]["messages"]]
    check("delete with confirmation expunges exactly that UID", c == 0 and r.get("permanently_deleted") and 4 not in msgs(s, "INBOX")
          and 5 in msgs(s, "INBOX") and len(trash_uids) == 1, r)
    new = srv.log_lines()[n_log:]
    sel = [i for i, l in enumerate(new) if " SELECT " in l]
    check("delete confirms UIDPLUS in its own session before SELECT", sel and any("CAPABILITY" in l for l in new[:sel[-1]][-3:]), new)
    check("delete uses UID EXPUNGE, not EXPUNGE", any(l.endswith("UID EXPUNGE 4") for l in srv.log_lines()[n_log:])
          and not any(l.split(" ", 1)[-1] == "EXPUNGE" for l in srv.log_lines()))


def compose(srv):
    att = os.path.join(srv.work, "report.txt")
    pathlib.Path(att).write_text("quarterly numbers\n")
    n_drafts = len(srv.st()["mailboxes"]["Drafts"]["messages"])
    c, r = tool(srv, "mail_save_draft", {"to": "a@example.com", "subject": "x", "body": "x", "attachments": [{"path": att}]})
    check("attachments are off without MAILBEND_ATTACH_DIR", c != 0 and "MAILBEND_ATTACH_DIR" in r.get("error", "")
          and len(srv.st()["mailboxes"]["Drafts"]["messages"]) == n_drafts, r)
    c, r = tool(srv, "mail_send", {"to": "a@example.com", "subject": "x", "body": "x", "attachments": [{"path": "/proc/self/environ"}]},
                MAILBEND_ATTACH_DIR=srv.work)
    check("attachments outside MAILBEND_ATTACH_DIR are refused (/proc/self/environ)", c != 0 and "outside" in r.get("error", "")
          and not srv.st().get("sent"), r)
    c, r = tool(srv, "mail_send", {"to": "a@example.com", "subject": "x", "body": "x", "attachments": [{"path": "../../../etc/hostname"}]},
                MAILBEND_ATTACH_DIR=srv.work)
    check("'..' cannot leave MAILBEND_ATTACH_DIR", c != 0 and "outside" in r.get("error", "") and not srv.st().get("sent"), r)
    link = os.path.join(srv.work, "link")
    os.symlink("/proc/self/environ", link)
    c, r = tool(srv, "mail_send", {"to": "a@example.com", "subject": "x", "body": "x", "attachments": [{"path": link}]},
                MAILBEND_ATTACH_DIR=srv.work)
    check("a symlink cannot escape MAILBEND_ATTACH_DIR", c != 0 and "outside" in r.get("error", "") and not srv.st().get("sent"), r)
    c, r = tool(srv, "mail_send", {"to": "a@example.com", "subject": "x", "body": "x", "attachments": [{"path": "environ"}]},
                MAILBEND_ATTACH_DIR="/proc/self")
    check("MAILBEND_ATTACH_DIR=/proc/self cannot mail out the environment", c != 0 and PASSWORD not in json.dumps(r)
          and not srv.st().get("sent"), r)
    c, r = tool(srv, "mail_send", {"to": "a@example.com", "subject": "x", "body": "x", "attachments": [{"path": "report.txt"}] * 33},
                MAILBEND_ATTACH_DIR=srv.work)
    check("at most 32 attachments per message", c != 0 and "32 attachments" in r.get("error", "") and not srv.st().get("sent"), r)
    p = subprocess.run([str(ROOT / "bin" / "mailbend-attach"), srv.work, "report.txt", "5"], capture_output=True, text=True)
    check("the reader refuses a file larger than the budget left, before reading it", p.returncode == 2
          and "exceed" in p.stderr and p.stdout == "", (p.returncode, p.stderr))
    c, r = tool(srv, "mail_save_draft", {"to": ["José Q <jose@example.com>"], "bcc": ["secret@example.com"], "subject": "Brouillon é",
                                         "body": "Draft body é\n.leading dot",
                                         "attachments": [{"path": att}, {"path": "report.txt", "filename": "rapport é.txt"}]},
                MAILBEND_ATTACH_DIR=srv.work)
    s = srv.st()
    drafts = s["mailboxes"]["Drafts"]["messages"]
    check("save_draft appends to Drafts with \\Draft", c == 0 and len(drafts) == n_drafts + 1 and "\\Draft" in drafts[-1]["flags"]
          and r.get("saved_to") == "Drafts" and isinstance(r.get("uid"), int), r)
    raw = drafts[-1]["raw"] if drafts else ""
    check("draft is 7-bit MIME with the attachment", all(ord(ch) < 128 for ch in raw) and "report.txt" in raw
          and "multipart/mixed" in raw and "=?UTF-8?B?" in raw, raw[:400])
    check("a saved draft keeps its Bcc recipients", "\r\nBcc: secret@example.com\r\n" in raw, raw[:400])
    c, r = tool(srv, "mail_get", {"folder": "Drafts", "uid": drafts[-1]["uid"] if drafts else 1})
    check("draft reads back: subject, body, attachment", c == 0 and r.get("subject") == "Brouillon é" and "Draft body é" in r.get("text", "")
          and any(a["filename"] == "report.txt" for a in r.get("attachments", [])), r)
    check("non-ASCII attachment names use RFC 2231 and read back", "filename*0*=utf-8''rapport%20%C3%A9.txt" in raw
          and "=?UTF-8?" not in raw.split("filename", 1)[-1].split("\r\n\r\n", 1)[0]
          and any(a["filename"] == "rapport é.txt" for a in r.get("attachments", [])), [a["filename"] for a in r.get("attachments", [])])

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

    n_sent = len(srv.st().get("sent", []))
    c, r = tool(srv, "mail_reply", {"uid": 2, "uidvalidity": 1700000001, "body": "x", "as_draft": "true"})
    check("a non-boolean as_draft is refused, not read as false (nothing sent)", c != 0 and "as_draft" in r.get("error", "")
          and len(srv.st().get("sent", [])) == n_sent, r)
    c, r = tool(srv, "mail_reply", {"uid": 2, "uidvalidity": 1700000001, "body": "x", "as-draft": True})
    check("a misspelt argument is refused (nothing sent)", c != 0 and "unknown argument" in r.get("error", "")
          and len(srv.st().get("sent", [])) == n_sent, r)
    c, r = tool(srv, "mail_reply", {"uid": 2, "uidvalidity": 1700000001})
    check("a reply missing its required body is refused (nothing sent)", c != 0 and "\"body\" is required" in r.get("error", "")
          and len(srv.st().get("sent", [])) == n_sent, r)
    p = subprocess.run([LAUNCHER, "call", "mail_save_draft", "null"], capture_output=True, text=True, env=srv.env(), timeout=120)
    check("CLI arguments must be a JSON object", p.returncode != 0 and "JSON object" in p.stdout, p.stdout)
    c, r = tool(srv, "mail_reply", {"uid": 2, "body": "Sounds good"})
    check("reply requires the folder's UIDVALIDITY", c != 0 and "uidvalidity" in r.get("error", ""), r)
    c, r = tool(srv, "mail_forward", {"uid": 2, "uidvalidity": 42, "to": ["boss@example.com"]})
    check("forward with a stale UIDVALIDITY sends nothing", c != 0 and "UIDVALIDITY" in r.get("error", "") and len(srv.st().get("sent", [])) == n, r)
    c, r = tool(srv, "mail_reply", {"uid": 2, "uidvalidity": 1700000001, "body": "Sounds good"})
    sent = srv.st().get("sent", [])
    orig_id = next(l for l in msgs(srv.st(), "INBOX")[2]["raw"].split("\r\n") if l.lower().startswith("message-id:")).split(":", 1)[1].strip()
    ok = c == 0 and len(sent) == n + 1
    data = sent[-1]["data"] if ok else ""
    check("reply sends to the original sender", ok and sent[-1]["rcpt_to"] == ["jose@example.com"], r)
    check("reply result says the quote covers the whole original", r.get("quoted_original_truncated") is False
          and r.get("quoted_bytes") == r.get("original_bytes") and r.get("quoted_bytes", 0) > 0, r)
    check("reply threads: In-Reply-To, References, Re: subject", ("In-Reply-To: " + orig_id) in data and orig_id in data.split("References:", 1)[-1]
          and "Subject: Re: " in data.replace("=?UTF-8?B?", "Subject: Re: ") , data[:500])
    c, r = tool(srv, "mail_reply", {"uid": 2, "uidvalidity": 1700000001, "body": "draft reply", "as_draft": True})
    check("reply as draft goes to Drafts", c == 0 and r.get("saved_to") == "Drafts" and len(srv.st()["mailboxes"]["Drafts"]["messages"]) == n_drafts + 2, r)

    alias = os.path.join(srv.work, "attach-alias")
    os.symlink(srv.work, alias)
    big = os.path.join(srv.work, "big.bin")
    pathlib.Path(big).write_bytes(b"x" * 300000)
    c, r = tool(srv, "mail_save_draft", {"to": "a@example.com", "subject": "big", "body": "Big original text",
                                         "attachments": [{"path": "big.bin"}]}, MAILBEND_ATTACH_DIR=alias)
    check("MAILBEND_ATTACH_DIR may itself be reached through a symlink", c == 0 and isinstance(r.get("uid"), int), r)
    big_uid = r.get("uid", 0)
    c, g = tool(srv, "mail_get", {"folder": "Drafts", "uid": big_uid})
    c, r = tool(srv, "mail_reply", {"folder": "Drafts", "uid": big_uid, "uidvalidity": g.get("uidvalidity") or 0,
                                    "body": "re big", "as_draft": True})
    c2, g2 = tool(srv, "mail_get", {"folder": "Drafts", "uid": r.get("uid", 0)})
    check("reply to an original over 256 KB says its quote may be incomplete", c == 0 and "Big original text" in g2.get("text", "")
          and "only its start was read" in g2.get("text", ""), (r, g2.get("text", "")[:600]))
    check("reply result marks the truncated quote (quoted_original_truncated, quoted_bytes, original_bytes)",
          r.get("quoted_original_truncated") is True and r.get("quoted_bytes") == 262144
          and r.get("original_bytes", 0) > 262144, r)
    c, r = tool(srv, "mail_save_draft", {"to": ["list@example.com", "Bob <BOB@example.com>"],
                                         "cc": ["bob@example.com", FIX["user"], "List <list@example.com>", "carol@example.com"],
                                         "subject": "team", "body": "hello team"})
    team_uid = r.get("uid", 0)
    c, r = tool(srv, "mail_reply", {"folder": "Drafts", "uid": team_uid, "uidvalidity": g.get("uidvalidity") or 0,
                                    "body": "re team", "reply_all": True, "as_draft": True})
    team = next((m["raw"] for m in srv.st()["mailboxes"]["Drafts"]["messages"] if m["uid"] == r.get("uid")), "")
    cc = next((l for l in team.split("\r\n\r\n", 1)[0].replace("\r\n ", " ").split("\r\n") if l.startswith("Cc:")), "")
    check("reply-all lists each recipient once and leaves out the sender's own address",
          c == 0 and cc.lower().count("list@example.com") == 1 and cc.lower().count("bob@example.com") == 1
          and "carol@example.com" in cc and FIX["user"] not in cc, (r, cc))

    c, r = tool(srv, "mail_forward", {"uid": 2, "uidvalidity": 1700000001, "to": ["boss@example.com"], "body": "FYI"})
    sent = srv.st().get("sent", [])
    data = sent[-1]["data"] if sent else ""
    check("forward attaches a 7-bit original as message/rfc822", c == 0 and sent[-1]["rcpt_to"] == ["boss@example.com"]
          and "Content-Type: message/rfc822" in data and "Content-Transfer-Encoding: 7bit" in data and "forwarded-message.eml" in data, r)
    c, r = tool(srv, "mail_forward", {"uid": 5, "uidvalidity": 1700000001, "to": ["boss@example.com"], "body": "FYI"})
    sent = srv.st().get("sent", [])
    data = sent[-1]["data"] if sent else ""
    check("forward attaches an 8-bit original as base64 (RFC 2046 forbids encoded message/rfc822)", c == 0
          and "Content-Type: application/octet-stream" in data and "forwarded-message.eml" in data
          and all(ord(ch) < 128 for ch in data), r)
    c, r = tool(srv, "mail_forward", {"uid": 2, "uidvalidity": 1700000001, "to": ["boss@example.com"], "body": "FYI",
                                      "attachments": [{"path": "report.txt"}]}, MAILBEND_ATTACH_DIR=srv.work)
    sent = srv.st().get("sent", [])
    data = sent[-1]["data"] if sent else ""
    check("forward with an attachment: original and file within one budget", c == 0 and "forwarded-message.eml" in data
          and "report.txt" in data, r)
    s = srv.st()
    check("reply/forward left the originals unread-state untouched", "\\Seen" not in flags(s, "INBOX", 2) and "\\Seen" in flags(s, "INBOX", 5))


def mcp_session(srv, requests, **env):
    p = subprocess.Popen([LAUNCHER, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         env=srv.env(**env))
    # raw bytes: a string request may carry lone surrogates standing for invalid UTF-8 bytes
    lines = [json.dumps(r) if not isinstance(r, str) else r for r in requests]
    out, err = p.communicate(b"\n".join(l.encode("utf-8", "surrogateescape") for l in lines) + b"\n", timeout=180)
    out, err = out.decode("utf-8"), err.decode("utf-8", "replace")
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
        '{"jsonrpc": "2.0" "id": 9, "method": "ping"}',
        {"jsonrpc": "2.0", "id": 5, "method": "resources/list"},
        {"jsonrpc": "2.0", "id": 6, "method": "ping"},
        {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "mail_save_draft", "arguments": "invalid"}},
        {"id": 8},
        5,
        {"jsonrpc": "2.0", "id": 11, "method": "initialize", "params": "invalid"},
        '{"jsonrpc": "2.0", "id": 12, "method": "ping", "x": "\udcff"}',
    ]
    res, code = mcp_session(srv, reqs)
    by_id = {r.get("id"): r for r in res}
    check("mcp: exactly one answer per request (none for the notification)", len(res) == 13, res)
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
    check("mcp: parse errors (garbage, a missing separator) answered with -32700",
          sum(1 for r in res if r.get("error", {}).get("code") == -32700) == 3 and 9 not in by_id, res)
    check("mcp: unknown method answered with -32601", by_id.get(5, {}).get("error", {}).get("code") == -32601, by_id.get(5))
    check("mcp: ping", by_id.get(6, {}).get("result") == {}, by_id.get(6))
    check("mcp: non-object params are refused, not cleared", by_id.get(11, {}).get("error", {}).get("code") == -32602, by_id.get(11))
    check("mcp: a line that is not valid UTF-8 is a parse error", 12 not in by_id, res)
    check("mcp: non-object tool arguments are refused, not cleared", by_id.get(7, {}).get("error", {}).get("code") == -32602, by_id.get(7))
    check("mcp: malformed envelopes answered with -32600", by_id.get(8, {}).get("error", {}).get("code") == -32600
          and any(r.get("id") is None and r.get("error", {}).get("code") == -32600 for r in res), res)
    check("mcp: exits cleanly when stdin closes", code == 0, code)


def read_only(srv):
    before = srv.st()
    c, r = tool(srv, "mail_trash", {"uids": [5], "uidvalidity": 1700000001}, MAILBEND_READ_ONLY="1")
    check("read-only mode refuses changes", c != 0 and "MAILBEND_READ_ONLY" in r.get("error", "") and srv.st() == before, r)
    c, r = tool(srv, "mail_search", {}, MAILBEND_READ_ONLY="1")
    check("read-only mode still allows reads", c == 0 and "messages" in r, r)


def failures(srv, work):
    c, r = tool(srv, "mail_probe", MAILBEND_CA_FILE=None)
    check("unknown CA is refused (TLS verification)", c != 0 and "TLS verification failed" in r.get("error", ""), r)
    c, r = tool(srv, "mail_probe", MAILBEND_IMAP_HOST="127.0.0.1")
    check("host name mismatch is refused", c != 0 and "TLS verification failed" in r.get("error", ""), r)
    c, r = tool(srv, "mail_probe", MAILBEND_TLS_HELPER="bin/mailbend-tls")
    check("a relative MAILBEND_TLS_HELPER is refused", c != 0 and "absolute path" in r.get("error", ""), r)
    c, r = tool(srv, "mail_probe", MAILBEND_APP_PASSWORD="wrong-password")
    check("wrong password reports authentication failure", c != 0 and "authentication failed" in r.get("error", ""), r)
    c, r = tool(srv, "mail_probe", MAILBEND_APP_PASSWORD=None)
    check("missing password is a configuration error", c != 0 and "MAILBEND_APP_PASSWORD" in r.get("error", ""), r)


def fallback(work):
    srv = Server(work, extra=["--special-on-request"])
    try:
        c, r = tool(srv, "mail_probe")
        asked = [l for l in srv.log_lines() if "RETURN (SPECIAL-USE)" in l]
        check("SPECIAL-USE marked only on request: roles asked with LIST RETURN (SPECIAL-USE)", c == 0 and asked
              and r["special_use"]["trash"] == "Deleted Messages" and r["special_use"]["drafts"] == "Drafts", (r, asked))
        c, r = tool(srv, "mail_trash", {"uids": [3], "uidvalidity": 1700000001})
        check("SPECIAL-USE marked only on request: trash uses the requested roles", c == 0 and 3 not in msgs(srv.st(), "INBOX"), r)
    finally:
        srv.stop()
    srv = Server(work, extra=["--special-on-request", "--special-return-fails"])
    try:
        before = srv.st()
        c, r = tool(srv, "mail_probe")
        check("role lookup fails: probe reports it instead of guessing names",
              c != 0 and "special-use folder roles" in r.get("error", ""), r)
        c, r = tool(srv, "mail_list_folders")
        check("role lookup fails: folder list reports it", c != 0 and "special-use folder roles" in r.get("error", ""), r)
        c, r = tool(srv, "mail_trash", {"uids": [3], "uidvalidity": 1700000001})
        check("role lookup fails: trash refused, nothing moved",
              c != 0 and "special-use folder roles" in r.get("error", "") and srv.st() == before, r)
        c, r = tool(srv, "mail_save_draft", {"to": ["bob@example.com"], "subject": "s", "body": "t"})
        check("role lookup fails: no draft saved",
              c != 0 and "special-use folder roles" in r.get("error", "") and srv.st() == before
              and not any(" APPEND " in l for l in srv.log_lines()), r)
    finally:
        srv.stop()
    srv = Server(work)
    try:
        c, r = tool(srv, "mail_probe")
        check("roles in the plain LIST: no second LIST session", c == 0 and not any("RETURN" in l for l in srv.log_lines()), r)
    finally:
        srv.stop()
    srv = Server(work, caps="UIDPLUS")
    try:
        c, r = tool(srv, "mail_probe")
        check("no SPECIAL-USE: folders found by name", c == 0 and r["special_use"]["trash"] == "Deleted Messages"
              and r["special_use"]["drafts"] == "Drafts" and not r["move"], r)
        c, r = tool(srv, "mail_move", {"uids": [3], "destination": "Archive", "uidvalidity": 1700000001})
        s = srv.st()
        check("no MOVE: copy + UID EXPUNGE of exactly those UIDs", c == 0 and r.get("method") == "UID COPY + UID EXPUNGE"
              and 3 not in msgs(s, "INBOX") and len(s["mailboxes"]["Archive"]["messages"]) == 1, r)
    finally:
        srv.stop()
    srv = Server(work, caps="")
    try:
        before = srv.st()
        c, r = tool(srv, "mail_move", {"uids": [3], "destination": "Archive", "uidvalidity": 1700000001})
        check("no MOVE or UIDPLUS: move refused", c != 0 and "neither MOVE nor UIDPLUS" in r.get("error", ""), r)
        c, r = tool(srv, "mail_delete", {"uids": [3], "confirm": "permanently-delete", "uidvalidity": 1700000001})
        check("no UIDPLUS: delete refused", c != 0 and "UIDPLUS" in r.get("error", "") and srv.st() == before, r)
        check("refusals sent no mutating command", not any(k in l for l in srv.log_lines() for k in (" STORE ", " EXPUNGE", " COPY ", " MOVE ")))
    finally:
        srv.stop()


if __name__ == "__main__":
    main()
