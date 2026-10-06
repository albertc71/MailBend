#!/usr/bin/env python3
"""End-to-end tests: every MailBend tool, through scripts/mailbend (CLI and
MCP stdio), against tests/fake_mail_server.py over verified TLS.

Checks tool results and the server's recorded state and command log: reads
never add \\Seen and never SELECT, deletion needs confirmation, trash is
recoverable, mail is actually delivered, and the password never appears in
any output. Run: python3 tests/test-e2e.py   (after scripts/install.sh)
"""
import base64
import copy
import json
import os
import pwd
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
LAUNCHER = str(ROOT / "scripts" / "mailbend")
FIXTURE = ROOT / "tests" / "fixtures" / "mailbox.json"
FIX = json.loads(FIXTURE.read_text(encoding="utf-8"))
PASSWORD = FIX["password"]
FOLDER_ROLES = ("drafts", "trash", "sent", "junk", "archive")
SEND_SETTINGS = ("MAILBEND_SAVE_SENT", "MAILBEND_ALLOWED_RECIPIENTS", "MAILBEND_MAX_SENDS_PER_DAY",
                 "MAILBEND_STATE_DIR")
FOLDER_COMMANDS = (" CREATE ", " RENAME ", " SUBSCRIBE ", " UNSUBSCRIBE ")
MUTATING_COMMANDS = (" APPEND ", " STORE ", " EXPUNGE", " COPY ", " MOVE ") + FOLDER_COMMANDS
TOOL_COUNT = 21
READ_TOOLS = ["mail_probe", "mail_list_folders", "mail_search", "mail_get", "mail_get_new", "mail_get_thread"]

results = []
outputs = []  # every stdout/stderr captured, scanned for the password at the end


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  -- " + str(detail)[:600]))


class Server:
    def __init__(self, work, caps=None, extra=(), fixture=None):
        self.work = work
        self.state = os.path.join(work, "state.json")
        self.log = os.path.join(work, "log.jsonl")
        for f in (self.state, self.log):
            if os.path.exists(f):
                os.remove(f)
        fixture_path = FIXTURE
        if fixture is not None:
            fixture_path = pathlib.Path(work) / "scenario-fixture.json"
            fixture_path.write_text(json.dumps(fixture), encoding="utf-8")
        cmd = [sys.executable, str(ROOT / "tests" / "fake_mail_server.py"), "--certdir", os.path.join(work, "certs"),
               "--fixture", str(fixture_path), "--state", self.state, "--log", self.log, *extra]
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
        for role in FOLDER_ROLES:
            e.pop(f"MAILBEND_{role.upper()}_FOLDER", None)
        e.pop("MAILBEND_READ_ONLY", None)
        e.pop("MAILBEND_DRAFTS_ONLY", None)
        e.pop("MAILBEND_PASSWORD_FILE", None)
        e.pop("MAILBEND_ATTACH_DIR", None)
        e.pop("MAILBEND_DOWNLOAD_DIR", None)
        e.pop("MAILBEND_TLS_HELPER", None)
        e.pop("MAILBEND_ATTACH_HELPER", None)
        for name in SEND_SETTINGS:
            e.pop(name, None)
        for k, v in over.items():
            if v is None:
                e.pop(k, None)
            else:
                e[k] = v
        return e

    def st(self):
        return json.loads(pathlib.Path(self.state).read_text(encoding="utf-8"))

    def log_records(self):
        path = pathlib.Path(self.log)
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]

    def log_lines(self):
        return [record["line"] for record in self.log_records()]

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc.stdout.close()


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
        cli_front_end(srv)
        read_only(srv)
        failures(srv, work)
    finally:
        srv.stop()
    fallback(work)
    generic_folders(work)
    folder_tools(work)
    flag_tools(work)
    send_safety(work)
    downloads(work)
    threads(work)


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


def attach(directory, path):
    p = subprocess.run([str(ROOT / "bin" / "mailbend-attach"), directory, path, "1000"], capture_output=True, text=True, timeout=10)
    return p.returncode, p.stderr


def attach_dir_guards(srv):
    c, err = attach("/", "etc/hostname")
    check("MAILBEND_ATTACH_DIR=/ is refused", c == 2 and "must not be /" in err, err)
    home = pwd.getpwuid(os.getuid()).pw_dir
    c, err = attach(home, ".profile")
    check("the home directory is refused as MAILBEND_ATTACH_DIR", c == 2 and "home directory" in err, err)
    c, err = attach(os.path.dirname(home) or "/", "x")
    check("a directory containing the home directory is refused", c == 2 and ("home directory" in err or "must not be /" in err), err)
    keys = os.path.join(srv.work, "with-keys")
    os.makedirs(os.path.join(keys, ".ssh"))
    pathlib.Path(keys, "a.txt").write_text("a")
    c, err = attach(keys, "a.txt")
    check("a directory holding .ssh is refused", c == 2 and ".ssh" in err, err)
    shutil.rmtree(keys)
    hard = os.path.join(srv.work, "hard.txt")
    os.link(os.path.join(srv.work, "report.txt"), hard)
    try:
        c, err = attach(srv.work, "hard.txt")
    finally:
        os.remove(hard)
    check("a file with another hard link is refused", c == 2 and "hard link" in err, err)
    fifo = os.path.join(srv.work, "pipe")
    os.mkfifo(fifo)
    try:
        c, err = attach(srv.work, "pipe")
    finally:
        os.remove(fifo)
    check("a FIFO is refused without being opened", c == 2 and "not a regular file" in err, err)
    c, err = attach(srv.work, "report.txt")
    check("a regular file in a dedicated directory is still read", c == 0, err)


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
    attach_dir_guards(srv)
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


def mcp_bytes(srv, data, **env):
    p = subprocess.Popen([LAUNCHER, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         env=srv.env(**env))
    out, err = p.communicate(data, timeout=180)
    out, err = out.decode("utf-8"), err.decode("utf-8", "replace")
    outputs.extend([out, err])
    return [json.loads(l) for l in out.splitlines() if l.strip()], p.returncode


def mcp_session(srv, requests, **env):
    # raw bytes: a string request may carry lone surrogates standing for invalid UTF-8 bytes
    lines = [json.dumps(r) if not isinstance(r, str) else r for r in requests]
    return mcp_bytes(srv, b"\n".join(l.encode("utf-8", "surrogateescape") for l in lines) + b"\n", **env)


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
    check(f"mcp: tools/list has all {TOOL_COUNT} tools with schemas", len(tools) == TOOL_COUNT and all("inputSchema" in t for t in tools), names)
    ann = {t["name"]: t.get("annotations", {}) for t in tools}
    check("mcp: read tools are marked read-only, delete destructive",
          all(ann[n]["readOnlyHint"] for n in READ_TOOLS)
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
    mcp_framing(srv)


def ping(i):
    return json.dumps({"jsonrpc": "2.0", "id": i, "method": "ping"}).encode()


def unknown_method(i, name):
    return json.dumps({"jsonrpc": "2.0", "id": i, "method": name}, ensure_ascii=False).encode()


def mcp_framing(srv):
    res, code = mcp_bytes(srv, ping(1) + b"\n\n  \r\n" + ping(2))
    check("mcp: blank lines are skipped and a last line without a newline is answered",
          [r.get("id") for r in res] == [1, 2] and code == 0, res)
    res, code = mcp_bytes(srv, b"")
    check("mcp: empty stdin ends the session without an answer", res == [] and code == 0, (res, code))
    res, code = mcp_bytes(srv, b"\n".join([ping(1), ping(2), ping(3)]) + b"\n")
    check("mcp: requests in one read are answered in order", [r.get("id") for r in res] == [1, 2, 3], res)
    # Lines longer than one 64 KiB read, whose two-byte characters straddle a read boundary
    # at either parity, are joined and decoded whole.
    names = ["x" + "é" * 50000, "xy" + "é" * 50000]
    res, _ = mcp_bytes(srv, b"\n".join(unknown_method(i, n) for i, n in enumerate(names)) + b"\n")
    check("mcp: a long line spanning reads is decoded whole",
          [r.get("error", {}).get("message") for r in res] == ["method not found: " + n for n in names], len(res))
    big = json.dumps({"jsonrpc": "2.0", "id": 3, "method": "ping", "pad": "a" * (8 * 1024 * 1024)}).encode()
    res, code = mcp_bytes(srv, ping(1) + b"\n" + big + b"\n" + ping(2) + b"\n")
    check("mcp: a line over 8 MiB is refused and ends the session",
          len(res) == 2 and res[0].get("id") == 1 and res[1].get("id") is None
          and res[1].get("error", {}).get("code") == -32600
          and res[1]["error"].get("message") == "request line longer than 8 MiB; closing" and code == 0, (res, code))


def cli(srv, *args):
    p = subprocess.run([LAUNCHER, *args], capture_output=True, text=True, env=srv.env(), timeout=120)
    outputs.extend([p.stdout, p.stderr])
    return p


USAGE = "usage: mailbend mcp | mailbend tools | mailbend call <tool> [json-arguments]"


def cli_front_end(srv):
    p = cli(srv, "version")
    check("cli: version", p.returncode == 0 and p.stdout == "mailbend 0.1.0\n", (p.returncode, p.stdout))
    for args in [(), ("help",), ("tools", "x"), ("call",), ("call", "mail_probe", "{}", "x"), ("mcp", "x")]:
        p = cli(srv, *args)
        check(f"cli: {list(args)} prints the usage and exits 2",
              p.returncode == 2 and USAGE in p.stderr and p.stdout == "", (p.returncode, p.stdout, p.stderr))
    p = cli(srv, "call", "mail_probe", "{not json")
    check("cli: arguments that are not JSON exit 2", p.returncode == 2 and p.stdout == ""
          and "the arguments are not valid JSON" in p.stderr, (p.returncode, p.stdout, p.stderr))
    p = cli(srv, "call", "nope")
    check("cli: a failed tool prints its JSON error and exits 1", p.returncode == 1
          and json.loads(p.stdout) == {"error": "unknown tool: nope"}
          and "mailbend: the tool failed" in p.stderr, (p.returncode, p.stdout, p.stderr))
    p = cli(srv, "call", "mail_probe")
    check("cli: call without arguments runs the tool with none", p.returncode == 0
          and json.loads(p.stdout).get("ok") is True, (p.returncode, p.stdout))


MUTATING_CALLS = {
    "mail_mark_read": {"uids": [5], "uidvalidity": 1700000001},
    "mail_mark_unread": {"uids": [5], "uidvalidity": 1700000001},
    "mail_flag": {"uids": [5], "uidvalidity": 1700000001, "colour": "blue"},
    "mail_unflag": {"uids": [5], "uidvalidity": 1700000001},
    "mail_move": {"uids": [5], "destination": "Archive", "uidvalidity": 1700000001},
    "mail_label": {"uids": [5], "label": "Archive", "uidvalidity": 1700000001},
    "mail_create_folder": {"name": "Projects"},
    "mail_rename_folder": {"from": "Work", "to": "Plans"},
    "mail_trash": {"uids": [5], "uidvalidity": 1700000001},
    "mail_delete": {"uids": [5], "uidvalidity": 1700000001, "confirm": "permanently-delete"},
    "mail_save_draft": {"to": "a@example.com", "subject": "x", "body": "x"},
    "mail_send": {"to": "a@example.com", "subject": "x", "body": "x"},
    "mail_reply": {"uid": 5, "uidvalidity": 1700000001, "body": "x"},
    "mail_forward": {"uid": 5, "uidvalidity": 1700000001, "to": "a@example.com"},
    "mail_get_attachment": {"uid": 4, "index": 0},
}


def listed_tools(srv, **env):
    p = subprocess.run([LAUNCHER, "tools"], capture_output=True, text=True, env=srv.env(**env), timeout=120)
    outputs.extend([p.stdout, p.stderr])
    return [t["name"] for t in json.loads(p.stdout)]


def read_only(srv):
    before, log_before = srv.st(), len(srv.log_lines())
    allowed = []
    for name, args in MUTATING_CALLS.items():
        c, r = tool(srv, name, args, MAILBEND_READ_ONLY="1")
        if not (c != 0 and "MAILBEND_READ_ONLY" in r.get("error", "")):
            allowed.append((name, r))
    check(f"read-only mode refuses all {len(MUTATING_CALLS)} mutating tools before connecting", not allowed and srv.st() == before
          and len(srv.log_lines()) == log_before, allowed)
    c, r = tool(srv, "mail_search", {}, MAILBEND_READ_ONLY="1")
    check("read-only mode still allows reads", c == 0 and "messages" in r, r)
    c, r = tool(srv, "mail_trash", {"uids": [5], "uidvalidity": 1700000001}, MAILBEND_READ_ONLY="TRUE")
    check("MAILBEND_READ_ONLY=TRUE is on", c != 0 and "MAILBEND_READ_ONLY is set" in r.get("error", ""), r)
    c, r = tool(srv, "mail_search", {}, MAILBEND_READ_ONLY="0")
    check("MAILBEND_READ_ONLY=0 is off", c == 0 and "messages" in r, r)
    unclear = []
    for value in ["yes", "on", " 1", "2"]:
        for name, args in [("mail_search", {}), ("mail_trash", {"uids": [5], "uidvalidity": 1700000001})]:
            c, r = tool(srv, name, args, MAILBEND_READ_ONLY=value)
            if not (c != 0 and "MAILBEND_READ_ONLY must be" in r.get("error", "")):
                unclear.append((value, name, r))
    c, r = tool(srv, "mail_search", {}, MAILBEND_DRAFTS_ONLY="sure")
    if not (c != 0 and "MAILBEND_DRAFTS_ONLY must be" in r.get("error", "")):
        unclear.append(("sure", "drafts", r))
    check("unrecognized switch values fail every tool instead of reading as off", not unclear and srv.st() == before, unclear)

    check(f"tools lists all {TOOL_COUNT} tools by default", len(listed_tools(srv)) == TOOL_COUNT)
    check(f"read-only mode lists only the {len(READ_TOOLS)} read tools",
          listed_tools(srv, MAILBEND_READ_ONLY="1") == READ_TOOLS)
    check("a misconfigured switch lists only the read tools", listed_tools(srv, MAILBEND_READ_ONLY="yes") == READ_TOOLS)
    names = listed_tools(srv, MAILBEND_DRAFTS_ONLY="1")
    check("drafts-only mode hides mail_send", len(names) == TOOL_COUNT - 1 and "mail_send" not in names and "mail_reply" in names, names)
    res, code = mcp_session(srv, [{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}], MAILBEND_READ_ONLY="1")
    names = [t["name"] for t in res[0].get("result", {}).get("tools", [])] if res else []
    check("mcp: tools/list in read-only mode offers only the read tools", names == READ_TOOLS, res)

    sent_before = len(srv.st().get("sent", []))
    refused = []
    for name in ["mail_send", "mail_reply", "mail_forward"]:
        c, r = tool(srv, name, MUTATING_CALLS[name], MAILBEND_DRAFTS_ONLY="1")
        if not (c != 0 and "MAILBEND_DRAFTS_ONLY" in r.get("error", "")):
            refused.append((name, r))
    check("drafts-only mode refuses every send", not refused and len(srv.st().get("sent", [])) == sent_before, refused)
    n_drafts = len(srv.st()["mailboxes"]["Drafts"]["messages"])
    c, r = tool(srv, "mail_reply", {**MUTATING_CALLS["mail_reply"], "as_draft": True}, MAILBEND_DRAFTS_ONLY="1")
    check("drafts-only mode still saves a reply as a draft", c == 0 and len(srv.st()["mailboxes"]["Drafts"]["messages"]) == n_drafts + 1
          and len(srv.st().get("sent", [])) == sent_before, r)
    c, r = tool(srv, "mail_save_draft", MUTATING_CALLS["mail_save_draft"], MAILBEND_DRAFTS_ONLY="1")
    check("drafts-only mode still saves drafts", c == 0 and r.get("saved_to") == "Drafts", r)


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
    password_file(srv, work)
    p = subprocess.run([LAUNCHER, "tools"], capture_output=True, text=True, env=srv.env(), timeout=120)
    outputs.extend([p.stdout, p.stderr])
    check("MAILBEND_CA_FILE prints a warning that it replaces the trust store", "warning" in p.stderr
          and "MAILBEND_CA_FILE" in p.stderr, p.stderr)


def password_file(srv, work):
    work = os.path.realpath(work)
    pw = os.path.join(work, "password")
    with open(os.open(pw, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        f.write(PASSWORD + "\n")
    c, r = tool(srv, "mail_probe", MAILBEND_APP_PASSWORD=None, MAILBEND_PASSWORD_FILE=pw)
    check("MAILBEND_PASSWORD_FILE logs in without the password in any environment", c == 0 and r.get("ok"), r)
    c, r = tool(srv, "mail_probe", MAILBEND_PASSWORD_FILE=pw)
    check("the password from both the environment and a file is refused", c != 0 and "not both" in r.get("error", ""), r)
    c, r = tool(srv, "mail_probe", MAILBEND_APP_PASSWORD=None, MAILBEND_PASSWORD_FILE="password")
    check("a relative MAILBEND_PASSWORD_FILE is refused", c != 0 and "absolute path" in r.get("error", ""), r)
    link = os.path.join(work, "password-link")
    os.symlink(pw, link)
    c, r = tool(srv, "mail_probe", MAILBEND_APP_PASSWORD=None, MAILBEND_PASSWORD_FILE=link)
    check("a symlinked MAILBEND_PASSWORD_FILE is refused", c != 0 and "symlink" in r.get("error", ""), r)
    linked_dir = os.path.join(work, "password-dir")
    os.symlink(work, linked_dir)
    c, r = tool(srv, "mail_probe", MAILBEND_APP_PASSWORD=None, MAILBEND_PASSWORD_FILE=os.path.join(linked_dir, "password"))
    check("a MAILBEND_PASSWORD_FILE under a symlinked directory is refused", c != 0 and "symlink" in r.get("error", ""), r)
    os.remove(linked_dir)
    os.chmod(pw, 0o644)
    c, r = tool(srv, "mail_probe", MAILBEND_APP_PASSWORD=None, MAILBEND_PASSWORD_FILE=pw)
    check("a MAILBEND_PASSWORD_FILE readable by others is refused", c != 0 and "chmod 600" in r.get("error", ""), r)
    os.remove(link)
    os.remove(pw)


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
        check("roles in plain LIST still request complete SPECIAL-USE discovery",
              c == 0 and any("RETURN (SPECIAL-USE)" in line for line in srv.log_lines()), r)
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



def empty_mailbox(special=()):
    return {"uidvalidity": 1700000010, "special": list(special), "messages": []}


def draft_paths(srv, label, destination=None, **env):
    requests = (
        ("mail_save_draft", {"to": ["bob@example.com"], "subject": "generic draft", "body": "body"}),
        ("mail_reply", {"uid": 2, "uidvalidity": 1700000001, "body": "draft reply", "as_draft": True}),
        ("mail_forward", {"uid": 2, "uidvalidity": 1700000001, "to": ["bob@example.com"], "as_draft": True}),
    )
    for name, args in requests:
        before = srv.st()
        log_start = len(srv.log_lines())
        code, result = tool(srv, name, args, **env)
        after = srv.st()
        commands = srv.log_lines()[log_start:]
        if destination is None:
            check(f"{label}: {name} fails without mutation", code != 0 and bool(result.get("error"))
                  and after == before and not any(token in line for line in commands for token in MUTATING_COMMANDS),
                  (result, commands))
        else:
            appended = [line for line in commands if " APPEND " in line]
            check(f"{label}: {name} appends to {destination}", code == 0
                  and result.get("saved_to") == destination and len(appended) == 1
                  and len(after["mailboxes"][destination]["messages"]) ==
                  len(before["mailboxes"][destination]["messages"]) + 1, (result, appended))
        check(f"{label}: {name} sends nothing and preserves originals",
              after.get("sent", []) == before.get("sent", [])
              and after["mailboxes"]["INBOX"] == before["mailboxes"]["INBOX"]
              and not any(record.get("proto") == "smtp" for record in srv.log_records()[log_start:]), commands)


def generic_folders(work):
    # Resolve each role independently when providers advertise only a subset.
    for options in (["--omit-special-use", "Drafts,Sent"], ["--special-plain-roles", "Trash"],
                    ["--special-on-request", "--omit-special-use", "Drafts,Sent"]):
        srv = Server(work, extra=options)
        try:
            label = "partial roles " + " ".join(options)
            code, result = tool(srv, "mail_probe")
            roles = result.get("special_use", {})
            check(label + ": per-role resolution", code == 0 and roles.get("drafts") == "Drafts"
                  and roles.get("sent") == "Sent Messages" and roles.get("trash") == "Deleted Messages", result)
            check(label + ": extended LIST requested", any("RETURN (SPECIAL-USE)" in line for line in srv.log_lines()))
            code, result = tool(srv, "mail_list_folders")
            folders = {folder["name"]: folder for folder in result.get("folders", [])}
            check(label + ": ordinary folders retained", code == 0 and set(folders) == set(FIX["mailboxes"]), result)
            if "--omit-special-use" in options:
                check(label + ": listing does not invent fallback attributes",
                      folders.get("Drafts", {}).get("special_use") is None
                      and "\\Drafts" not in folders.get("Drafts", {}).get("attributes", []), folders.get("Drafts"))
            draft_paths(srv, label, "Drafts")
        finally:
            srv.stop()

    fixture = copy.deepcopy(FIX)
    fixture["mailboxes"]["Drafts"]["special"] = []
    localized = "Projets/Brouillons \u65e5\u672c"
    fixture["mailboxes"][localized] = empty_mailbox(["\\Drafts"])
    srv = Server(work, fixture=fixture)
    try:
        draft_paths(srv, "unique localized advertised role wins conventional name", localized)
    finally:
        srv.stop()

    fixture = copy.deepcopy(FIX)
    targets = {role: "Personnel/" + role + " \u65e5\u672c" for role in FOLDER_ROLES}
    for target in targets.values():
        fixture["mailboxes"][target] = empty_mailbox()
    srv = Server(work, fixture=fixture)
    try:
        overrides = {f"MAILBEND_{role.upper()}_FOLDER": target for role, target in targets.items()}
        code, result = tool(srv, "mail_probe", **overrides)
        check("all five overrides resolve exact decoded nested names", code == 0
              and all(result.get("special_use", {}).get(role) == target for role, target in targets.items()), result)
        draft_paths(srv, "explicit Drafts override wins advertised role", targets["drafts"], **overrides)
        code, result = tool(srv, "mail_trash", {"uids": [3], "uidvalidity": 1700000001}, **overrides)
        check("explicit Trash override controls move destination", code == 0
              and result.get("destination") == targets["trash"]
              and len(srv.st()["mailboxes"][targets["trash"]]["messages"]) == 1, result)
        before = srv.st()
        log_start = len(srv.log_lines())
        code, result = tool(srv, "mail_trash", {"uids": [4], "uidvalidity": 1700000001},
                            MAILBEND_TRASH_FOLDER="Missing/Trash")
        check("invalid Trash override refuses mutation", code != 0 and srv.st() == before
              and not any(token in line for line in srv.log_lines()[log_start:] for token in MUTATING_COMMANDS), result)
        for role in FOLDER_ROLES:
            variable = f"MAILBEND_{role.upper()}_FOLDER"
            code, result = tool(srv, "mail_probe", **{variable: targets[role].lower()})
            check(f"{variable} refuses non-INBOX case mismatch", code != 0 and bool(result.get("error")), result)
        code, result = tool(srv, "mail_probe", MAILBEND_DRAFTS_FOLDER="inbox")
        check("INBOX override is case-insensitive", code == 0 and result.get("special_use", {}).get("drafts") == "INBOX", result)
        draft_paths(srv, "unknown Drafts override", MAILBEND_DRAFTS_FOLDER="Missing/Drafts")
        draft_paths(srv, "override is not a substring", MAILBEND_DRAFTS_FOLDER="drafts")
        draft_paths(srv, "empty override uses regular resolution", "Drafts", MAILBEND_DRAFTS_FOLDER="")
    finally:
        srv.stop()

    cases = []
    fixture = copy.deepcopy(FIX)
    fixture["mailboxes"]["Other Drafts"] = empty_mailbox(["\\Drafts"])
    cases.append(("multiple advertised Drafts", fixture, {}))
    fixture = copy.deepcopy(FIX)
    fixture["mailboxes"]["Drafts"]["special"] = []
    fixture["mailboxes"]["Unavailable"] = empty_mailbox(["\\Drafts", "\\Noselect"])
    cases.append(("unselectable advertised role blocks conventional fallback", fixture, {}))
    fixture = copy.deepcopy(FIX)
    fixture["mailboxes"]["Drafts"]["special"] = ["\\Noselect"]
    cases.append(("unselectable conventional Drafts", fixture, {}))
    fixture = copy.deepcopy(FIX)
    fixture["mailboxes"]["Drafts"]["special"] = ["\\Sent"]
    cases.append(("Drafts name carrying conflicting role", fixture, {}))
    fixture = copy.deepcopy(FIX)
    del fixture["mailboxes"]["Drafts"]
    fixture["mailboxes"]["Drafts backup"] = empty_mailbox()
    cases.append(("conventional name is not a substring", fixture, {}))
    fixture = copy.deepcopy(FIX)
    fixture["mailboxes"]["Unavailable"] = empty_mailbox(["\\Noselect"])
    cases.append(("unselectable explicit override", fixture, {"MAILBEND_DRAFTS_FOLDER": "Unavailable"}))
    for label, fixture, env in cases:
        srv = Server(work, fixture=fixture)
        try:
            draft_paths(srv, label, **env)
            if label == "multiple advertised Drafts":
                draft_paths(srv, "explicit override resolves advertised ambiguity", "Other Drafts",
                            MAILBEND_DRAFTS_FOLDER="Other Drafts")
        finally:
            srv.stop()

    for role, alias, attribute in (("trash", "Trash", "\\Trash"), ("sent", "Sent", "\\Sent")):
        fixture = copy.deepcopy(FIX)
        for mailbox in fixture["mailboxes"].values():
            mailbox["special"] = [value for value in mailbox["special"] if value != attribute]
        fixture["mailboxes"][alias] = empty_mailbox()
        srv = Server(work, fixture=fixture)
        try:
            code, result = tool(srv, "mail_probe")
            check(f"ambiguous conventional {role} aliases unresolved", code == 0
                  and result.get("special_use", {}).get(role) is None, result)
            if role == "trash":
                before = srv.st()
                log_start = len(srv.log_lines())
                code, result = tool(srv, "mail_trash", {"uids": [3], "uidvalidity": 1700000001})
                check("ambiguous Trash aliases refuse mutation", code != 0 and srv.st() == before
                      and not any(token in line for line in srv.log_lines()[log_start:] for token in MUTATING_COMMANDS), result)
            draft_paths(srv, f"ambiguous {role} does not block Drafts", "Drafts")
        finally:
            srv.stop()

    srv = Server(work, extra=["--special-plain-roles", "Trash", "--special-return-fails"])
    try:
        draft_paths(srv, "partial roles do not hide failed extended LIST")
        for name in ("mail_probe", "mail_list_folders"):
            code, result = tool(srv, name)
            check(f"failed extended LIST after partial plain roles: {name}", code != 0
                  and "special-use folder roles" in result.get("error", ""), result)
    finally:
        srv.stop()


# ---- folders and labels -------------------------------------------------------------------

FOLDER_TREES = ("Mail", "Mail/Sent", "Deep", "Deep/A", "Deep/A/B", "Taken/Projects", "Stage", "Stage/Sent",
                "Out/Sent", "Receipts", "Deleted Messages/Old")
SUBSCRIBED = ("Work", "Work/Projects")
INBOX_VALIDITY = 1700000001
NO_MOVE_CAPS = "UIDPLUS,SPECIAL-USE,IDLE"


def folder_fixture(delim):
    """The shared fixture plus ordinary folder trees, with levels joined by `delim`."""
    fixture = copy.deepcopy(FIX)
    for name in FOLDER_TREES:
        fixture["mailboxes"][name] = empty_mailbox()
    fixture["mailboxes"]["Hierarchy"] = empty_mailbox(["\\Noselect"])
    fixture["mailboxes"] = {name.replace("/", delim): box for name, box in fixture["mailboxes"].items()}
    fixture["subscribed"] = [name.replace("/", delim) for name in SUBSCRIBED]
    return fixture


def refused(srv, title, name, args, needle, **env):
    """The call fails with `needle` in its error and sends no command that changes anything."""
    before, log_start = srv.st(), len(srv.log_lines())
    code, result = tool(srv, name, args, **env)
    changing = [line for line in srv.log_lines()[log_start:] if any(token in line for token in MUTATING_COMMANDS)]
    check(title, code != 0 and needle in result.get("error", "") and srv.st() == before and not changing, (result, changing))


def folder_commands_since(srv, log_start):
    """The folder commands sent since `log_start`, without their tags."""
    return [line.split(" ", 1)[1] for line in srv.log_lines()[log_start:] if any(t in line for t in FOLDER_COMMANDS)]


def folder_tools(work):
    for delim in ("/", "."):
        srv = Server(work, fixture=folder_fixture(delim), extra=["--delim", delim])
        try:
            folder_create(srv, delim)
            folder_rename(srv, delim)
            check(f"[{delim}] no folder tool sends DELETE or a plain EXPUNGE",
                  not any(" DELETE " in line or line.split(" ", 1)[-1] == "EXPUNGE" for line in srv.log_lines()))
        finally:
            srv.stop()
        for caps in (None, NO_MOVE_CAPS):
            folder_label(work, delim, caps)
    folder_unknown_delimiter(work)
    folder_subscription_failure(work)
    folder_cut_off(work)
    folder_partial_over_mcp(work)
    for case in INTERRUPTED_LABELS:
        folder_interrupted(work, *case)


def folder_create(srv, delim):
    tag = f"[{delim}] create: "
    at = delim.join
    log_start = len(srv.log_lines())
    code, result = tool(srv, "mail_create_folder", {"name": "Projects"})
    state = srv.st()
    check(tag + "a new folder is made and subscribed", code == 0 and result.get("folder") == "Projects"
          and result.get("subscribed") is True and "Projects" in state["mailboxes"] and "Projects" in state["subscribed"], result)
    check(tag + "CREATE comes before SUBSCRIBE", folder_commands_since(srv, log_start) == ['CREATE "Projects"', 'SUBSCRIBE "Projects"'],
          folder_commands_since(srv, log_start))
    check(tag + "the new folder is listed with the server's delimiter", any(
        folder["name"] == "Projects" and folder["delimiter"] == delim
        for folder in tool(srv, "mail_list_folders")[1].get("folders", [])))
    refused(srv, tag + "a name that is taken is refused", "mail_create_folder", {"name": "Projects"}, "already exists")
    for name in ("inbox", "INBOX", "Drafts", "Sent Messages", "Deleted Messages", "trash", "Junk", "Archive",
                 at(["Archive", "2025"]), at(["Deleted Messages", "Work"]), at(["trash", "x"])):
        refused(srv, tag + f"{name!r} is protected", "mail_create_folder", {"name": name}, "relies on")
    refused(srv, tag + "a missing parent is refused, not created", "mail_create_folder", {"name": at(["Nowhere", "Child"])},
            "does not exist")
    refused(srv, tag + "a trailing delimiter is refused", "mail_create_folder", {"name": at(["Work", ""])}, "empty level")
    refused(srv, tag + "an empty name is refused", "mail_create_folder", {"name": ""}, "empty")
    refused(srv, tag + "a line break in a name is refused", "mail_create_folder", {"name": "a\nb"}, "control characters")
    refused(srv, tag + "a tab in a name is refused", "mail_create_folder", {"name": "a\tb"}, "control characters")
    refused(srv, tag + "a role folder configured by the user is protected", "mail_create_folder",
            {"name": at(["Mail", "Sent"])}, "relies on", MAILBEND_SENT_FOLDER=at(["Mail", "Sent"]))
    code, result = tool(srv, "mail_create_folder", {"name": at(["Work", "Invoices"])})
    check(tag + "a folder under an existing ordinary parent", code == 0 and at(["Work", "Invoices"]) in srv.st()["mailboxes"], result)
    code, result = tool(srv, "mail_create_folder", {"name": "Reçus 日本"})
    check(tag + "a non-ASCII name goes out in modified UTF-7", code == 0 and "Reçus 日本" in srv.st()["mailboxes"]
          and 'CREATE "Re&AOc-us &ZeVnLA-"' in " ".join(srv.log_lines()), result)
    inbox_child = at(["INBOX", "Plans"])
    code, result = tool(srv, "mail_create_folder", {"name": at(["inbox", "Plans"])})
    check(tag + "a lower-case inbox prefix is sent as the listed INBOX", code == 0 and result.get("folder") == inbox_child
          and inbox_child in srv.st()["mailboxes"] and f'CREATE "{inbox_child}"' in " ".join(srv.log_lines()), result)
    code, result = tool(srv, "mail_create_folder", {"name": "To Delete"})
    check(tag + "the review folder may be created", code == 0 and "To Delete" in srv.st()["mailboxes"], result)
    refused(srv, tag + "the review folder only once", "mail_create_folder", {"name": "To Delete"}, "already exists")
    refused(srv, tag + "the review folder only at top level", "mail_create_folder", {"name": at(["To Delete", "x"])}, "relies on")


def folder_rename(srv, delim):
    """Continues on the server folder_create used: Work then also holds Invoices."""
    tag = f"[{delim}] rename: "
    at = delim.join
    sent_override = {"MAILBEND_SENT_FOLDER": at(["Mail", "Sent"])}
    refused(srv, tag + "a folder holding a configured role folder is not renamed", "mail_rename_folder",
            {"from": "Mail", "to": "Post"}, "cannot be renamed", **sent_override)
    refused(srv, tag + "a subfolder that would land on a configured role folder is refused", "mail_rename_folder",
            {"from": "Stage", "to": "Out"}, "subfolder", MAILBEND_SENT_FOLDER=at(["Out", "Sent"]))
    for source in ("inbox", "Archive", "Sent Messages", "Deleted Messages"):
        refused(srv, tag + f"{source!r} cannot be renamed", "mail_rename_folder", {"from": source, "to": "Other"}, "cannot be renamed")
    refused(srv, tag + "a missing folder is refused", "mail_rename_folder", {"from": "Nope", "to": "Other"}, "no folder is named")
    refused(srv, tag + "Work cannot move under Trash", "mail_rename_folder", {"from": "Work", "to": at(["Trash", "Work"])}, "relies on")
    refused(srv, tag + "Work cannot move under the Trash folder", "mail_rename_folder",
            {"from": "Work", "to": at(["Deleted Messages", "Work"])}, "relies on")
    refused(srv, tag + "a missing parent is refused, not created", "mail_rename_folder",
            {"from": "Work", "to": at(["Missing", "Work"])}, "does not exist")
    refused(srv, tag + "an existing folder is not replaced", "mail_rename_folder", {"from": "Work", "to": "日本"}, "already exists")
    refused(srv, tag + "a role folder name is not a destination", "mail_rename_folder", {"from": "Work", "to": "Archive"}, "relies on")
    refused(srv, tag + "a folder cannot move into itself", "mail_rename_folder", {"from": "Work", "to": at(["Work", "Sub"])}, "into itself")
    refused(srv, tag + "a subfolder colliding with an existing folder is refused", "mail_rename_folder",
            {"from": "Work", "to": "Taken"}, "subfolder")

    log_start = len(srv.log_lines())
    subscribed_before = set(srv.st()["subscribed"])
    code, result = tool(srv, "mail_rename_folder", {"from": "Work", "to": "Plans"})
    state = srv.st()
    check(tag + "a tree follows its root", code == 0 and result.get("subscribed") is True
          and {"Plans", at(["Plans", "Projects"]), at(["Plans", "Invoices"])} <= set(state["mailboxes"])
          and not {"Work", at(["Work", "Projects"]), at(["Work", "Invoices"])} & set(state["mailboxes"]), result)
    commands = folder_commands_since(srv, log_start)
    moved = [name for name in ("Work", at(["Work", "Projects"]), at(["Work", "Invoices"])) if name in subscribed_before]
    new_names = ["Plans" + name[len("Work"):] for name in moved]
    count = len(moved)
    check(tag + "RENAME, then every SUBSCRIBE, then every UNSUBSCRIBE, only for folders that were subscribed",
          count == 3 and len(commands) == 1 + 2 * count and commands[0] == 'RENAME "Work" "Plans"'
          and set(commands[1:1 + count]) == {f'SUBSCRIBE "{n}"' for n in new_names}
          and set(commands[1 + count:]) == {f'UNSUBSCRIBE "{o}"' for o in moved}, commands)
    check(tag + "the subscription state is exactly the moved names", set(state["subscribed"]) == (subscribed_before - set(moved)) | set(new_names),
          state["subscribed"])
    subscribed_before = set(srv.st()["subscribed"])
    code, result = tool(srv, "mail_rename_folder", {"from": "Deep", "to": "Renamed"})
    names = set(srv.st()["mailboxes"])
    check(tag + "folders that were not subscribed stay unsubscribed", set(srv.st()["subscribed"]) == subscribed_before, srv.st()["subscribed"])
    check(tag + "a three-level tree follows its root", code == 0 and {"Renamed", at(["Renamed", "A"]), at(["Renamed", "A", "B"])} <= names
          and not {"Deep", at(["Deep", "A"]), at(["Deep", "A", "B"])} & names, result)
    code, result = tool(srv, "mail_rename_folder", {"from": "Mail", "to": "Post"})
    check(tag + "the same folder is renamed once no role depends on it", code == 0 and at(["Post", "Sent"]) in srv.st()["mailboxes"], result)
    inbox_child = at(["INBOX", "Receipts"])
    code, result = tool(srv, "mail_rename_folder", {"from": "Receipts", "to": at(["inbox", "Receipts"])})
    check(tag + "a lower-case inbox prefix is sent as the listed INBOX", code == 0 and result.get("to") == inbox_child
          and inbox_child in srv.st()["mailboxes"] and f'RENAME "Receipts" "{inbox_child}"' in " ".join(srv.log_lines()), result)


def original_message(uid):
    return next(m for m in FIX["mailboxes"]["INBOX"]["messages"] if m["uid"] == uid)


def copies_of(state, raw):
    return sum(1 for box in state["mailboxes"].values() for m in box["messages"] if m["raw"] == raw)


def folder_label(work, delim, caps):
    method = "UID COPY + UID EXPUNGE" if caps == NO_MOVE_CAPS else "UID MOVE"
    tag = f"[{delim}] label ({method}): "
    srv = Server(work, caps=caps, fixture=folder_fixture(delim), extra=["--delim", delim])
    try:
        raw = original_message(3)["raw"]
        code, result = tool(srv, "mail_label", {"uids": [3], "label": "Receipts", "uidvalidity": INBOX_VALIDITY})
        state = srv.st()
        check(tag + "the message moves into the label folder", code == 0 and result.get("method") == method
              and result.get("changed") == [3] and result.get("destination") == "Receipts" and 3 not in msgs(state, "INBOX")
              and [m["raw"] for m in state["mailboxes"]["Receipts"]["messages"]] == [raw], result)
        check(tag + "the message exists exactly once", copies_of(state, raw) == 1, state["mailboxes"])
        label_uid = state["mailboxes"]["Receipts"]["messages"][0]["uid"]
        label_validity = state["mailboxes"]["Receipts"]["uidvalidity"]
        for name in ("Archive", "Deleted Messages", "Sent Messages", delim.join(["Deleted Messages", "Old"])):
            refused(srv, tag + f"{name!r} is not a label", "mail_label",
                    {"uids": [5], "label": name, "uidvalidity": INBOX_VALIDITY}, "relies on")
        refused(srv, tag + "INBOX is not a label", "mail_label",
                {"folder": "Receipts", "uids": [label_uid], "label": "inbox", "uidvalidity": label_validity}, "relies on")
        refused(srv, tag + "a missing label folder is refused, not created", "mail_label",
                {"uids": [5], "label": "Nowhere", "uidvalidity": INBOX_VALIDITY}, "does not exist")
        refused(srv, tag + "a folder that cannot be selected is refused", "mail_label",
                {"uids": [5], "label": "Hierarchy", "uidvalidity": INBOX_VALIDITY}, "cannot be selected")
        refused(srv, tag + "the folder the messages are in is refused", "mail_label",
                {"uids": [5], "label": "inbox", "uidvalidity": INBOX_VALIDITY}, "other than")
        refused(srv, tag + "a stale UIDVALIDITY is refused", "mail_label",
                {"uids": [5], "label": "Receipts", "uidvalidity": 42}, "UIDVALIDITY")
        refused(srv, tag + "UIDVALIDITY is required", "mail_label", {"uids": [5], "label": "Receipts"}, "uidvalidity")

        code, result = tool(srv, "mail_move", {"folder": "Receipts", "uids": [label_uid], "destination": "INBOX",
                                              "uidvalidity": label_validity})
        state = srv.st()
        check(tag + "moving back to INBOX removes the label", code == 0 and not state["mailboxes"]["Receipts"]["messages"]
              and copies_of(state, raw) == 1 and raw in [m["raw"] for m in state["mailboxes"]["INBOX"]["messages"]], result)
    finally:
        srv.stop()


def folder_unknown_delimiter(work):
    """A server whose LIST gives no delimiter for INBOX, or for any folder."""
    srv = Server(work, fixture=folder_fixture("/"), extra=["--nil-delim", "INBOX"])
    try:
        refused(srv, "INBOX without a delimiter: the other folders' delimiter still protects Trash", "mail_create_folder",
                {"name": "Deleted Messages/Work"}, "relies on")
        refused(srv, "INBOX without a delimiter: a missing parent is still refused", "mail_create_folder",
                {"name": "Nowhere/Child"}, "does not exist")
    finally:
        srv.stop()
    srv = Server(work, fixture=folder_fixture("/"), extra=["--nil-delim", "*"])
    try:
        refused(srv, "no delimiter at all: a nested-looking name is refused, not guessed", "mail_create_folder",
                {"name": "Deleted Messages/Work"}, "hierarchy delimiter")
        refused(srv, "no delimiter at all: a dotted name is refused too", "mail_rename_folder",
                {"from": "Work", "to": "a.b"}, "hierarchy delimiter")
        code, result = tool(srv, "mail_create_folder", {"name": "Flat"})
        check("no delimiter at all: a flat name is still created", code == 0 and "Flat" in srv.st()["mailboxes"], result)
    finally:
        srv.stop()


def folder_subscription_failure(work):
    """The change went through but a subscription command failed: success, not an error to retry."""
    srv = Server(work, fixture=folder_fixture("/"), extra=["--reject", "SUBSCRIBE"])
    try:
        code, result = tool(srv, "mail_create_folder", {"name": "Projects"})
        state = srv.st()
        check("create with SUBSCRIBE refused: the folder exists, unsubscribed, with a note not to retry",
              code == 0 and result.get("ok") is True and result.get("subscribed") is False and "Do not retry" in result.get("note", "")
              and "may not show it" in result["note"] and "Projects" in state["mailboxes"] and "Projects" not in state["subscribed"], result)
        before = set(state["subscribed"])
        code, result = tool(srv, "mail_rename_folder", {"from": "Work", "to": "Plans"})
        state = srv.st()
        check("rename with SUBSCRIBE refused: renamed, old subscriptions untouched, with a note not to retry",
              code == 0 and result.get("subscribed") is False and "Do not retry" in result.get("note", "")
              and "Plans" in state["mailboxes"] and set(state["subscribed"]) == before, result)
    finally:
        srv.stop()
    srv = Server(work, fixture=folder_fixture("/"), extra=["--reject", "UNSUBSCRIBE"])
    try:
        before = set(srv.st()["subscribed"])
        code, result = tool(srv, "mail_rename_folder", {"from": "Work", "to": "Plans"})
        state = srv.st()
        check("rename with UNSUBSCRIBE refused: every new name is subscribed, the old names say so in the note",
              code == 0 and result.get("subscribed") is False and "Do not retry" in result.get("note", "")
              and "old subscriptions" in result["note"] and "may not show" not in result["note"]
              and {"Plans", "Plans/Projects"} <= set(state["subscribed"]) and before <= set(state["subscribed"]), result)
    finally:
        srv.stop()


def folder_cut_off(work):
    """The connection drops around the change: after it ran but before the answer, or before it started."""
    changes = (("mail_create_folder", {"name": "Projects"}, "created", "Projects"),
               ("mail_rename_folder", {"from": "Work", "to": "Plans"}, "renamed", "Plans"))
    srv = Server(work, fixture=folder_fixture("/"), extra=["--drop-unanswered", "CREATE,RENAME"])
    try:
        for name, args, verb, made in changes:
            code, result = tool(srv, name, args)
            check(f"{name} cut off before the answer: an error that says to look before retrying",
                  code != 0 and f"may have been {verb}" in result.get("error", "") and "list the folders" in result["error"]
                  and made in srv.st()["mailboxes"], result)
    finally:
        srv.stop()
    for name, args, verb, made in changes:
        # the discovery session is the first CAPABILITY; the second one opens the change session
        srv = Server(work, fixture=folder_fixture("/"), extra=["--drop-unanswered", "CAPABILITY#2"])
        try:
            before = srv.st()
            code, result = tool(srv, name, args)
            check(f"{name} cut off before the change started: a plain error, nothing changed",
                  code != 0 and result.get("error") and "may have been" not in result["error"] and srv.st() == before, result)
        finally:
            srv.stop()
    srv = Server(work, fixture=folder_fixture("/"), extra=["--reject", "CREATE"])
    try:
        before = srv.st()
        code, result = tool(srv, "mail_create_folder", {"name": "Projects"})
        check("create refused by the server: a plain error, nothing changed", code != 0 and "may have been" not in result.get("error", "x")
              and "rejected" in result.get("error", "") and srv.st() == before, result)
    finally:
        srv.stop()


# A label (copy + expunge, no MOVE) whose session is cut off or refused: (title, server options, whether
# the result is partial, whether the copy really ran). The helper cannot tell a COPY it never got to send
# from one the server dropped unanswered, so a cut-off right after SEARCH is partial too.
INTERRUPTED_LABELS = (
    ("cut off after STORE", ["--drop-after", "STORE"], True, True),
    ("cut off after COPY", ["--drop-after", "COPY"], True, True),
    ("cut off before COPY was answered", ["--drop-unanswered", "COPY"], True, True),
    ("cut off after SEARCH", ["--drop-after", "SEARCH"], True, False),
    ("refused at COPY", ["--reject", "COPY"], False, False),
    ("cut off before SEARCH", ["--drop-after", "SELECT"], False, False),
)


def folder_interrupted(work, title, extra, partial, copied):
    tag = f"label {title}: "
    srv = Server(work, caps=NO_MOVE_CAPS, fixture=folder_fixture("/"), extra=extra)
    try:
        code, result = tool(srv, "mail_label", {"uids": [3], "label": "Receipts", "uidvalidity": INBOX_VALIDITY})
        state = srv.st()
        raw = original_message(3)["raw"]
        if not partial:
            check(tag + "nothing changed", copies_of(state, raw) == 1 and 3 in msgs(state, "INBOX")
                  and not state["mailboxes"]["Receipts"]["messages"], state["mailboxes"])
            check(tag + "a plain error, not partial", code != 0 and "partial" not in result and result.get("error"), result)
            return
        check(tag + "the messages are where the cut-off left them", copies_of(state, raw) == (2 if copied else 1)
              and 3 in msgs(state, "INBOX"), state["mailboxes"])
        if "STORE" in extra:
            check(tag + "the source copy is already marked \\Deleted", "\\Deleted" in flags(state, "INBOX", 3), flags(state, "INBOX", 3))
        message = result.get("message", "")
        check(tag + "the call fails as partial, not as an error that implies nothing changed", code != 0
              and result.get("partial") is True and result.get("ok") is False and "error" not in result
              and "both INBOX and Receipts" in message and "before retrying" in message, result)
        code, result = tool(srv, "mail_move", {"uids": [5], "destination": "Archive", "uidvalidity": INBOX_VALIDITY})
        check(tag + "mail_move reports the same", code != 0 and result.get("partial") is True
              and "both INBOX and Archive" in result.get("message", ""), result)
    finally:
        srv.stop()


def folder_partial_over_mcp(work):
    """A partial move is an isError result over MCP, with its structured body."""
    srv = Server(work, caps=NO_MOVE_CAPS, fixture=folder_fixture("/"), extra=["--drop-after", "COPY"])
    try:
        call = {"name": "mail_label", "arguments": {"uids": [3], "label": "Receipts", "uidvalidity": INBOX_VALIDITY}}
        res, _ = mcp_session(srv, [{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": call}])
        result = res[0].get("result", {}) if res else {}
        body = json.loads(result.get("content", [{}])[0].get("text", "{}"))
        check("mcp: a partial move is an isError result that keeps ok false and partial true",
              result.get("isError") is True and body.get("partial") is True and body.get("ok") is False, res)
    finally:
        srv.stop()


def colour_bit_numbers(state, uid):
    """The numbers N of the $MailFlagBitN keywords an INBOX message has."""
    return {n for n in range(3) if f"$MailFlagBit{n}" in flags(state, "INBOX", uid)}


def reported(result):
    """The result's flags entries as {uid: flags}, and whether each UID has exactly one."""
    entries = result.get("flags", [])
    uids = [e.get("uid") for e in entries]
    return {e.get("uid"): e.get("flags") for e in entries}, len(uids) == len(set(uids))


LIMITED_PERMANENT = "\\Seen,\\Flagged,\\Deleted,\\Draft,\\Answered"


def flag_tools(work):
    flag_basics(work)
    flag_noisy_server(work)
    flag_session_only(work)
    flag_dropped_colour(work)
    flag_without_permanent_flags(work)
    flag_unobserved(work)
    flag_cut_off(work)
    flag_helper_failures(work)


def flag_basics(work):
    srv = Server(work)
    try:
        c, r = tool(srv, "mail_flag", {"uids": [1, 2], "uidvalidity": INBOX_VALIDITY})
        s = srv.st()
        seen, single = reported(r)
        check("flag without a colour stores only \\Flagged and reports no colour",
              c == 0 and r.get("changed") == [1, 2] and r.get("missing") == [] and r.get("flagged") is True
              and all("\\Flagged" in flags(s, "INBOX", u) and not colour_bit_numbers(s, u) for u in (1, 2))
              and not {"colour", "colour_kept", "colour_not_kept"} & set(r), r)
        check("flag reports one flags entry per changed UID, as the server sent it",
              single and sorted(seen) == [1, 2] and all("\\Flagged" in f for f in seen.values()), r)
        c, r = tool(srv, "mail_flag", {"uids": [1], "uidvalidity": INBOX_VALIDITY, "colour": "green"})
        check("flag with a colour stores its bits (green = Bit0 + Bit1) and reports it kept",
              c == 0 and colour_bit_numbers(srv.st(), 1) == {0, 1} and r.get("colour") == "green"
              and r.get("colour_kept") is True and r.get("colour_not_kept") == [], r)
        c, r = tool(srv, "mail_flag", {"uids": [1], "uidvalidity": INBOX_VALIDITY, "colour": "blue"})
        check("flag with another colour replaces the bits (blue = Bit2)",
              c == 0 and colour_bit_numbers(srv.st(), 1) == {2} and r.get("colour_kept") is True, r)
        c, r = tool(srv, "mail_flag", {"uids": [1], "uidvalidity": INBOX_VALIDITY})
        check("flag without a colour keeps an existing blue",
              c == 0 and colour_bit_numbers(srv.st(), 1) == {2} and "\\Flagged" in flags(srv.st(), "INBOX", 1), r)
        c, r = tool(srv, "mail_flag", {"uids": [1], "uidvalidity": INBOX_VALIDITY, "colour": "red"})
        check("an explicit red clears the colour bits", c == 0 and not colour_bit_numbers(srv.st(), 1)
              and r.get("colour") == "red" and r.get("colour_kept") is True, r)
        tool(srv, "mail_flag", {"uids": [1], "uidvalidity": INBOX_VALIDITY, "colour": "purple"})
        c, r = tool(srv, "mail_unflag", {"uids": [1, 5, 99], "uidvalidity": INBOX_VALIDITY})
        s = srv.st()
        check("unflag clears \\Flagged and every colour bit, and keeps other flags",
              c == 0 and r.get("changed") == [1, 5] and r.get("missing") == [99] and r.get("flagged") is False
              and all("\\Flagged" not in flags(s, "INBOX", u) and not colour_bit_numbers(s, u) for u in (1, 5))
              and "\\Seen" in flags(s, "INBOX", 5) and "colour" not in r, r)
        before, n_log = srv.st(), len(srv.log_lines())
        c, r = tool(srv, "mail_flag", {"uids": [2], "uidvalidity": INBOX_VALIDITY, "colour": "pink"})
        check("an unknown colour is refused before anything is sent", c != 0 and "colour" in r.get("error", "")
              and srv.st() == before and len(srv.log_lines()) == n_log, r)
        c, r = tool(srv, "mail_flag", {"uids": [2], "uidvalidity": 42, "colour": "red"})
        new = srv.log_lines()[n_log:]
        check("flag with a stale UIDVALIDITY stops after SELECT, before any STORE",
              c != 0 and "UIDVALIDITY" in r.get("error", "") and srv.st() == before
              and any(" SELECT " in l for l in new) and not any(" STORE " in l for l in new), (r, new))
        c, r = tool(srv, "mail_flag", {"uids": [2], "uidvalidity": INBOX_VALIDITY, "colour": "purple"},
                    MAILBEND_READ_ONLY="1")
        check("read-only mode refuses mail_flag before connecting", c != 0 and "MAILBEND_READ_ONLY" in r.get("error", "")
              and srv.st() == before, r)
        c, r = tool(srv, "mail_flag", {"uids": [2], "uidvalidity": INBOX_VALIDITY, "colour": "grey"},
                    MAILBEND_DRAFTS_ONLY="1")
        check("drafts-only mode still allows flagging", c == 0 and colour_bit_numbers(srv.st(), 2) == {1, 2}, r)
        stores = [l for l in srv.log_lines() if " STORE " in l]
        check("flag stores only \\Flagged and colour bits, never \\Deleted",
              stores and all(("\\Flagged" in l or "$MailFlagBit" in l) and "\\Deleted" not in l for l in stores), stores[:3])
    finally:
        srv.stop()


def flag_noisy_server(work):
    """Unsolicited, duplicate, FLAGS-less and sequence-number-only FETCH updates."""
    srv = Server(work, extra=["--noisy-store"])
    try:
        c, r = tool(srv, "mail_flag", {"uids": [1], "uidvalidity": INBOX_VALIDITY, "colour": "green"})
        seen, single = reported(r)
        check("noisy FETCH updates still give one flags entry and colour_kept true",
              c == 0 and single and sorted(seen) == [1] and "$MailFlagBit1" in seen[1]
              and r.get("colour_kept") is True and r.get("colour_not_kept") == [], r)
    finally:
        srv.stop()


def flag_session_only(work):
    """PERMANENTFLAGS without the keywords, but the server stores them for the session."""
    srv = Server(work, extra=["--permanent-flags", LIMITED_PERMANENT, "--session-flags"])
    try:
        c, r = tool(srv, "mail_flag", {"uids": [1, 2], "uidvalidity": INBOX_VALIDITY, "colour": "orange"})
        check("session-only colour keywords give colour_kept false for every changed UID",
              c == 0 and all(colour_bit_numbers(srv.st(), u) == {0} for u in (1, 2))
              and r.get("colour_kept") is False and r.get("colour_not_kept") == [1, 2], r)
        c, r = tool(srv, "mail_flag", {"uids": [1], "uidvalidity": INBOX_VALIDITY, "colour": "red"})
        check("clearing session-only bits is not kept either", c == 0 and r.get("colour_kept") is False
              and r.get("colour_not_kept") == [1], r)
    finally:
        srv.stop()


def flag_dropped_colour(work):
    """PERMANENTFLAGS without the keywords, and the server drops them."""
    srv = Server(work, extra=["--permanent-flags", LIMITED_PERMANENT])
    try:
        c, r = tool(srv, "mail_flag", {"uids": [1, 2], "uidvalidity": INBOX_VALIDITY, "colour": "orange"})
        s = srv.st()
        seen, _ = reported(r)
        check("a colour the server drops is reported as not kept",
              c == 0 and r.get("colour_kept") is False and r.get("colour_not_kept") == [1, 2]
              and all("\\Flagged" in flags(s, "INBOX", u) and not colour_bit_numbers(s, u) for u in (1, 2))
              and all("$MailFlagBit0" not in f for f in seen.values()), r)
    finally:
        srv.stop()


def flag_without_permanent_flags(work):
    srv = Server(work, extra=["--no-permanent-flags"])
    try:
        c, r = tool(srv, "mail_flag", {"uids": [1], "uidvalidity": INBOX_VALIDITY, "colour": "green"})
        check("without PERMANENTFLAGS a colour is unverified, not kept",
              c == 0 and colour_bit_numbers(srv.st(), 1) == {0, 1} and r.get("colour_kept") == "unverified"
              and r.get("colour_not_kept") == [], r)
    finally:
        srv.stop()


def flag_unobserved(work):
    """A changed message whose flags the server does not report back."""
    srv = Server(work, extra=["--fetch-no-flags", "2"])
    try:
        c, r = tool(srv, "mail_flag", {"uids": [1, 2], "uidvalidity": INBOX_VALIDITY, "colour": "green"})
        seen, single = reported(r)
        check("a changed UID without reported flags makes the colour unverified, with flags null",
              c == 0 and single and sorted(seen) == [1, 2] and seen[2] is None and "$MailFlagBit1" in seen[1]
              and r.get("colour_kept") == "unverified" and r.get("colour_not_kept") == [], r)
    finally:
        srv.stop()


def flag_stopped(work, title, extra, name, args, acknowledged, unconfirmed, uids=(5,), **env):
    """A flag change stopped by a fault: partial when a store was acknowledged or may have run
    unanswered, else a plain error that changed nothing. Returns the server state after the call."""
    srv = Server(work, extra=extra)
    try:
        before = srv.st()
        c, r = tool(srv, name, {"uids": list(uids), "uidvalidity": INBOX_VALIDITY, **args}, **env)
        after = srv.st()
        if not acknowledged and not unconfirmed:
            check(title + ": a plain error, not partial, and nothing changed", c != 0 and "partial" not in r
                  and r.get("error") and after == before, r)
            return after
        check(title + ": partial, with the acknowledged and possibly-run changes", c != 0
              and r.get("partial") is True and r.get("ok") is False and "error" not in r
              and r.get("acknowledged") == acknowledged and r.get("unconfirmed") == unconfirmed
              and "idempotent" in r.get("message", ""), r)
        return after
    finally:
        srv.stop()


def flag_cut_off(work):
    flag_stopped(work, "a refused colour store", ["--reject", "STORE#3"], "mail_flag", {"colour": "blue"},
                 ["+\\Flagged", "-$MailFlagBit0"], [])
    flag_stopped(work, "a colour store cut off unanswered", ["--drop-unanswered", "STORE#2"], "mail_flag",
                 {"colour": "blue"}, ["+\\Flagged"], ["-$MailFlagBit0"])
    flag_stopped(work, "an unflag whose cleanup is refused", ["--reject", "STORE#2"], "mail_unflag", {},
                 ["-\\Flagged"], [])
    flag_stopped(work, "a refused first store", ["--reject", "STORE#1"], "mail_flag", {"colour": "blue"}, [], [])
    flag_stopped(work, "an unflag of absent UIDs whose cleanup is refused", ["--reject", "STORE#2"],
                 "mail_unflag", {}, [], [], uids=(99,))
    for title, args in (("a first colour store", {"colour": "blue"}), ("a first store", {})):
        s = flag_stopped(work, title + " cut off unanswered", ["--drop-unanswered", "STORE#1"], "mail_flag",
                         args, [], ["+\\Flagged"], uids=(2,))
        check(title + " cut off unanswered really ran", "\\Flagged" in flags(s, "INBOX", 2), flags(s, "INBOX", 2))
    srv = Server(work, extra=["--reject", "FETCH#1"])
    try:
        c, r = tool(srv, "mail_flag", {"uids": [5], "uidvalidity": INBOX_VALIDITY, "colour": "green"})
        check("a refused read-back after every store: partial, saying every change was acknowledged",
              c != 0 and r.get("partial") is True and r.get("unconfirmed") == []
              and r.get("acknowledged") == ["+\\Flagged", "+$MailFlagBit0", "+$MailFlagBit1", "-$MailFlagBit2"]
              and "acknowledged every" in r.get("message", "") and "refused a store" not in r.get("message", "")
              and colour_bit_numbers(srv.st(), 5) == {0, 1}, r)
    finally:
        srv.stop()


def flag_helper_failures(work):
    """A helper that never started changed nothing; one killed by a signal may have."""
    flag_stopped(work, "a relative helper path", [], "mail_flag", {"colour": "blue"}, [], [],
                 MAILBEND_TLS_HELPER="bin/mailbend-tls")
    flag_stopped(work, "a helper that does not exist", [], "mail_flag", {"colour": "blue"}, [], [],
                 MAILBEND_TLS_HELPER=os.path.join(work, "no-such-helper"))
    killed = os.path.join(work, "killed-helper")
    with open(killed, "w", encoding="utf-8") as f:
        f.write("#!/bin/sh\nkill -KILL $$\n")
    os.chmod(killed, 0o755)
    flag_stopped(work, "a helper killed by a signal", [], "mail_flag", {"colour": "blue"}, [],
                 ["+\\Flagged", "-$MailFlagBit0", "-$MailFlagBit1", "+$MailFlagBit2"], MAILBEND_TLS_HELPER=killed)


# --------------------------------------------------------------------------
# Send safety: the recipient allowlist, the Sent copy and the daily limit
# --------------------------------------------------------------------------

SEND = {"to": "friend@example.com", "subject": "safety", "body": "x"}


def sent_count(srv):
    return len(srv.st().get("sent", []))


def send_safety(work):
    srv = Server(work)
    try:
        send_settings(srv)
        allowlist(srv)
        daily_limit(srv, work)
    finally:
        srv.stop()
    sent_copies(work)
    allowlist_reply_all(work)


def send_settings(srv):
    bad = []
    for name, value in [("MAILBEND_SAVE_SENT", "yes"), ("MAILBEND_ALLOWED_RECIPIENTS", "example.com"),
                        ("MAILBEND_ALLOWED_RECIPIENTS", "a@example.com,"),
                        ("MAILBEND_ALLOWED_RECIPIENTS", "@example.com (work)"), ("MAILBEND_MAX_SENDS_PER_DAY", "0"),
                        ("MAILBEND_MAX_SENDS_PER_DAY", "ten"), ("MAILBEND_STATE_DIR", "relative/state")]:
        c, r = tool(srv, "mail_send", SEND, **{name: value})
        if not (c != 0 and "configuration error" in r.get("error", "") and name in r.get("error", "")):
            bad.append((name, value, r))
    check("a malformed send setting refuses the send instead of reading as off", not bad and sent_count(srv) == 0, bad)
    c, r = tool(srv, "mail_save_draft", SEND, MAILBEND_SAVE_SENT="yes", MAILBEND_ALLOWED_RECIPIENTS="example.com")
    check("send settings never apply to drafts", c == 0 and r.get("saved_to") == "Drafts", r)
    c, r = tool(srv, "mail_search", {}, MAILBEND_MAX_SENDS_PER_DAY="ten")
    check("send settings leave reads alone", c == 0 and "messages" in r, r)
    on = {"MAILBEND_SAVE_SENT": "1", "MAILBEND_ALLOWED_RECIPIENTS": "@example.com", "MAILBEND_MAX_SENDS_PER_DAY": "5"}
    names = listed_tools(srv, MAILBEND_DRAFTS_ONLY="1", **on)
    c, r = tool(srv, "mail_send", SEND, MAILBEND_DRAFTS_ONLY="1", **on)
    check("drafts-only mode still hides and refuses mail_send with the send settings on",
          "mail_send" not in names and c != 0 and "MAILBEND_DRAFTS_ONLY" in r.get("error", ""), (names, r))
    check("read-only mode still lists only the read tools with the send settings on",
          listed_tools(srv, MAILBEND_READ_ONLY="1", **on) == READ_TOOLS)


def allowlist(srv):
    allow = {"MAILBEND_ALLOWED_RECIPIENTS": "@example.com, Boss@Partner.org"}
    c, r = tool(srv, "mail_send", {**SEND, "cc": ["Boss <boss@partner.ORG>"], "bcc": ["Team@EXAMPLE.com"]}, **allow)
    sent = srv.st().get("sent", [])
    check("allowlist: listed addresses and domains are sent to, in any case", c == 0 and len(sent) == 1
          and set(sent[-1]["rcpt_to"]) == {"friend@example.com", "boss@partner.ORG", "Team@EXAMPLE.com"}, r)
    refused = []
    for name, args, who in [
            ("mail_send", {**SEND, "bcc": ["spy@other.org"]}, "spy@other.org"),
            ("mail_send", {**SEND, "to": "x@partner.org"}, "x@partner.org"),
            ("mail_send", {**SEND, "to": "a@sub.example.com"}, "a@sub.example.com"),
            ("mail_send", {**SEND, "to": "a%evil.org@example.com"}, "a%evil.org@example.com"),
            ("mail_send", {**SEND, "to": "a!b@example.com"}, "a!b@example.com"),
            ("mail_forward", {"uid": 2, "uidvalidity": 1700000001, "to": ["out@other.org"]}, "out@other.org")]:
        c, r = tool(srv, name, args, **allow)
        if not (c != 0 and "MAILBEND_ALLOWED_RECIPIENTS" in r.get("error", "") and who in r.get("error", "")):
            refused.append((name, who, r))
    check("allowlist: any unlisted or source-routed recipient refuses the whole message", not refused
          and sent_count(srv) == 1, refused)
    c, r = tool(srv, "mail_reply", {"uid": 2, "uidvalidity": 1700000001, "body": "x"},
                MAILBEND_ALLOWED_RECIPIENTS="alice@example.com")
    check("allowlist: a reply to an unlisted sender is refused", c != 0 and "jose@example.com" in r.get("error", "")
          and sent_count(srv) == 1, r)
    c, r = tool(srv, "mail_forward", {"uid": 2, "uidvalidity": 1700000001, "to": ["out@other.org"], "as_draft": True},
                **allow)
    check("allowlist: a forward saved as a draft is not checked", c == 0 and r.get("saved_to") == "Drafts", r)


def allowlist_reply_all(work):
    fixture = copy.deepcopy(FIX)
    original = fixture["mailboxes"]["INBOX"]["messages"][1]
    original["raw"] = original["raw"].replace("To: tester@example.com\r\n",
                                              "To: tester@example.com\r\nCc: outsider@other.org\r\n", 1)
    srv = Server(work, fixture=fixture)
    try:
        allow = {"MAILBEND_ALLOWED_RECIPIENTS": "@example.com"}
        reply = {"uid": 2, "uidvalidity": 1700000001, "body": "x"}
        c, r = tool(srv, "mail_reply", {**reply, "reply_all": True}, **allow)
        check("allowlist: reply-all checks the original's Cc too", c != 0 and "outsider@other.org" in r.get("error", "")
              and sent_count(srv) == 0, r)
        c, r = tool(srv, "mail_reply", reply, **allow)
        check("allowlist: a reply to a listed sender is sent", c == 0 and sent_count(srv) == 1
              and srv.st()["sent"][-1]["rcpt_to"] == ["jose@example.com"], r)
    finally:
        srv.stop()


def daily_limit(srv, work):
    state = os.path.join(os.path.realpath(work), "send-state", "mailbend")
    limit = {"MAILBEND_MAX_SENDS_PER_DAY": "2", "MAILBEND_STATE_DIR": state}
    n = sent_count(srv)
    answers = [tool(srv, "mail_send", SEND, **limit) for _ in range(3)]
    check("daily limit: sends below and at the limit go", [c for c, _ in answers[:2]] == [0, 0]
          and sent_count(srv) == n + 2, answers[:2])
    c, r = answers[2]
    check("daily limit: a send over the limit is refused before SMTP", c != 0 and "daily send limit" in r.get("error", "")
          and sent_count(srv) == n + 2, r)
    counter = pathlib.Path(state, "sends")
    check("daily limit: the counter lives in the state directory, created private",
          counter.is_file() and len(counter.read_text().splitlines()) == 2
          and (os.stat(state).st_mode & 0o777) == 0o700, state)
    c, r = tool(srv, "mail_save_draft", SEND, **limit)
    check("daily limit: drafts are not counted", c == 0 and r.get("saved_to") == "Drafts"
          and len(counter.read_text().splitlines()) == 2, r)
    c, r = tool(srv, "mail_send", SEND, MAILBEND_MAX_SENDS_PER_DAY="3", MAILBEND_STATE_DIR=state)
    check("daily limit: a higher limit allows the next send", c == 0 and sent_count(srv) == n + 3, r)

    other = os.path.join(os.path.realpath(work), "send-state-failed")
    c, r = tool(srv, "mail_send", {**SEND, "to": "reject@example.com"}, MAILBEND_MAX_SENDS_PER_DAY="1",
                MAILBEND_STATE_DIR=other)
    c2, r2 = tool(srv, "mail_send", SEND, MAILBEND_MAX_SENDS_PER_DAY="1", MAILBEND_STATE_DIR=other)
    check("daily limit: a send the server refused still counts", c != 0 and "550" in r.get("error", "")
          and c2 != 0 and "daily send limit" in r2.get("error", "") and sent_count(srv) == n + 3, (r, r2))

    blocked = os.path.join(os.path.realpath(work), "not-a-directory")
    pathlib.Path(blocked).write_text("")
    unusable = os.path.join(os.path.realpath(work), "counter-is-a-directory")
    os.makedirs(os.path.join(unusable, "sends"))
    refused = []
    for directory in (blocked, unusable):
        c, r = tool(srv, "mail_send", SEND, MAILBEND_MAX_SENDS_PER_DAY="5", MAILBEND_STATE_DIR=directory)
        if not (c != 0 and "MAILBEND_MAX_SENDS_PER_DAY" in r.get("error", "")):
            refused.append((directory, r))
    check("daily limit: a state directory or counter that cannot be used refuses the send", not refused
          and sent_count(srv) == n + 3, refused)

    xdg = os.path.join(os.path.realpath(work), "xdg-state")
    c, r = tool(srv, "mail_send", SEND, MAILBEND_MAX_SENDS_PER_DAY="5", XDG_STATE_HOME=xdg)
    check("daily limit: the counter defaults to $XDG_STATE_HOME/mailbend", c == 0
          and pathlib.Path(xdg, "mailbend", "sends").is_file(), r)


def sent_message(srv, box, message_id):
    return [m for m in srv.st()["mailboxes"].get(box, {}).get("messages", []) if message_id in m["raw"]]


def sent_copies(work):
    srv = Server(work)
    try:
        c, r = tool(srv, "mail_send", SEND)
        check("without MAILBEND_SAVE_SENT nothing is copied to Sent", c == 0 and "sent_copy" not in r
              and not srv.st()["mailboxes"]["Sent Messages"]["messages"], r)
        log_start = len(srv.log_lines())
        c, r = tool(srv, "mail_send", {**SEND, "bcc": ["hidden@example.com"]}, MAILBEND_SAVE_SENT="1")
        copies = sent_message(srv, "Sent Messages", r.get("message_id", "?"))
        commands = srv.log_lines()[log_start:]
        check("a sent message is copied to the advertised Sent folder", c == 0
              and r.get("sent_copy") == "saved to Sent Messages" and len(copies) == 1
              and copies[0]["flags"] == ["\\Seen"], r)
        check("the Sent copy keeps its Bcc, as a draft does", copies and "\r\nBcc: hidden@example.com\r\n" in copies[0]["raw"]
              and "hidden@example.com" not in srv.st()["sent"][-1]["data"], copies[:1])
        check("the Sent copy is looked for read-only first", any(" EXAMINE " in l and "Sent Messages" in l for l in commands)
              and any("SEARCH" in l and "HEADER" in l for l in commands) and not any(" SELECT " in l for l in commands),
              commands)
        c, r = tool(srv, "mail_send", SEND, MAILBEND_SAVE_SENT="1", MAILBEND_SENT_FOLDER="Nowhere")
        check("a Sent copy that cannot be made is reported beside the successful send", c == 0 and r.get("sent")
              and r.get("sent_copy", "").startswith("failed: ") and "MAILBEND_SENT_FOLDER" in r.get("sent_copy", ""), r)
    finally:
        srv.stop()

    srv = Server(work, extra=["--file-sent", "Sent Messages"])
    try:
        log_start = len(srv.log_lines())
        c, r = tool(srv, "mail_send", SEND, MAILBEND_SAVE_SENT="1")
        copies = sent_message(srv, "Sent Messages", r.get("message_id", "?"))
        check("mail the server already filed is not copied again", c == 0
              and r.get("sent_copy") == "already in Sent Messages" and len(copies) == 1
              and not any(" APPEND " in l for l in srv.log_lines()[log_start:]), r)
    finally:
        srv.stop()

    srv = Server(work, extra=["--reject", "APPEND"])
    try:
        c, r = tool(srv, "mail_send", SEND, MAILBEND_SAVE_SENT="1")
        check("a refused Sent copy fails only the copy", c == 0 and r.get("sent") and sent_count(srv) == 1
              and r.get("sent_copy", "").startswith("failed or unconfirmed (check Sent Messages before saving again): "), r)
    finally:
        srv.stop()

    fixture = copy.deepcopy(FIX)
    fixture["mailboxes"]["Sent"] = fixture["mailboxes"].pop("Sent Messages")
    fixture["mailboxes"]["Sent"]["special"] = []
    srv = Server(work, fixture=fixture)
    try:
        c, r = tool(srv, "mail_send", SEND, MAILBEND_SAVE_SENT="1")
        check("a Sent folder found by its conventional name Sent takes the copy", c == 0
              and r.get("sent_copy") == "saved to Sent" and len(sent_message(srv, "Sent", r.get("message_id", "?"))) == 1, r)
    finally:
        srv.stop()

    fixture = copy.deepcopy(FIX)
    del fixture["mailboxes"]["Sent Messages"]
    srv = Server(work, fixture=fixture)
    try:
        before = srv.st()["mailboxes"]
        c, r = tool(srv, "mail_send", SEND, MAILBEND_SAVE_SENT="1")
        check("without a Sent folder the send goes and says no copy was kept", c == 0 and r.get("sent")
              and r.get("sent_copy", "").startswith("not saved: ") and srv.st()["mailboxes"] == before, r)
    finally:
        srv.stop()


# --------------------------------------------------------------------------
# Attachment downloads: mail_get_attachment and mailbend-attach save
# --------------------------------------------------------------------------

ALL_BYTES = bytes(range(256))
FILES_UID, HUGE_UID, CUT_UID = 7, 8, 9


def file_part(header_name, body):
    return ("--files\r\nContent-Type: text/plain\r\n"
            f"Content-Disposition: attachment; {header_name}\r\n\r\n{body}\r\n")


def download_fixture():
    """INBOX gains a message whose attachments are every byte, then names to
    sanitise; a copy the server claims is larger than 25 MB; and a copy
    padded past the 25 MB fetch whose size the server under-reports."""
    fixture = copy.deepcopy(FIX)
    files = ("Message-ID: <msg7@example.com>\r\nDate: Sun, 27 Sep 2026 09:00:00 +0000\r\n"
             "From: carol@example.com\r\nTo: tester@example.com\r\nSubject: Files\r\nMIME-Version: 1.0\r\n"
             "Content-Type: multipart/mixed; boundary=\"files\"\r\n\r\n"
             "--files\r\nContent-Type: text/plain\r\n\r\nThe files.\r\n"
             "--files\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n"
             "Content-Disposition: attachment; filename=\"all.bin\"\r\n\r\n"
             + base64.b64encode(ALL_BYTES).decode() + "\r\n"
             + file_part('filename="../../evil.sh"', "echo hi")
             + file_part("filename*=UTF-8''%E2%80%AEgpj.exe", "x")
             + file_part('filename="...hidden"', "y"))
    line = "x" * 76 + "\r\n"
    padding = "--files\r\nContent-Type: text/plain\r\n\r\n" + line * ((25 << 20) // len(line) + 1)
    message = {"uid": FILES_UID, "flags": [], "internaldate": "27-Sep-2026 09:00:00 +0000",
               "raw": files + "--files--\r\n"}
    huge = {**message, "uid": HUGE_UID, "reported_size": 26 << 20}
    cut = {**message, "uid": CUT_UID, "raw": files + padding + "--files--\r\n", "reported_size": 1000}
    fixture["mailboxes"]["INBOX"]["messages"] += [message, huge, cut]
    return fixture


def downloads(work):
    root = os.path.join(os.path.realpath(work), "download-tests")
    dl = os.path.join(root, "downloads")
    os.makedirs(dl)
    srv = Server(work, fixture=download_fixture())
    try:
        download_settings(srv, dl)
        download_round_trip(srv, dl)
        download_names(srv, dl)
        download_directories(srv, root)
    finally:
        srv.stop()
    killed_download(root)


def get_attachment(srv, index, uid=FILES_UID, **env):
    return tool(srv, "mail_get_attachment", {"uid": uid, "index": index}, **env)


def download_settings(srv, dl):
    c, r = get_attachment(srv, 0)
    check("downloads are off without MAILBEND_DOWNLOAD_DIR", c != 0 and "downloads are disabled" in r.get("error", ""), r)
    c, r = get_attachment(srv, 0, MAILBEND_DOWNLOAD_DIR="downloads")
    check("a relative MAILBEND_DOWNLOAD_DIR is a configuration error", c != 0
          and "configuration error: MAILBEND_DOWNLOAD_DIR" in r.get("error", ""), r)
    c, r = get_attachment(srv, 0, MAILBEND_DOWNLOAD_DIR=dl, MAILBEND_READ_ONLY="1")
    check("read-only mode refuses mail_get_attachment", c != 0 and "MAILBEND_READ_ONLY" in r.get("error", "")
          and not os.listdir(dl), r)
    c, r = get_attachment(srv, 0, uid=HUGE_UID, MAILBEND_DOWNLOAD_DIR=dl)
    check("a message too large to fetch whole is refused", c != 0 and "larger than 25 MB" in r.get("error", "")
          and not os.listdir(dl), r)
    c, r = get_attachment(srv, 0, uid=CUT_UID, MAILBEND_DOWNLOAD_DIR=dl)
    check("a fetch cut at 25 MB is refused even when the server under-reports the size", c != 0
          and "larger than 25 MB" in r.get("error", "") and not os.listdir(dl), r)
    c, r = get_attachment(srv, 9, MAILBEND_DOWNLOAD_DIR=dl)
    check("a missing attachment index is refused", c != 0 and "no attachment 9" in r.get("error", ""), r)


def download_round_trip(srv, dl):
    log_start = len(srv.log_lines())
    c, r = get_attachment(srv, 0, MAILBEND_DOWNLOAD_DIR=dl)
    saved = os.path.join(dl, "all.bin")
    check("mail_get_attachment saves every byte 0x00-0xFF unchanged", c == 0 and r.get("path") == saved
          and r.get("size") == 256 and pathlib.Path(saved).read_bytes() == ALL_BYTES, r)
    check("a saved attachment is private (mode 0600)", (os.stat(saved).st_mode & 0o777) == 0o600)
    commands = srv.log_lines()[log_start:]
    check("a download reads with EXAMINE and BODY.PEEK and leaves the message unread",
          any(" EXAMINE " in l for l in commands) and any("BODY.PEEK[]" in l for l in commands)
          and not any(" SELECT " in l for l in commands) and flags(srv.st(), "INBOX", FILES_UID) == set(), commands)
    pathlib.Path(saved).write_bytes(b"kept")
    c, r = get_attachment(srv, 0, MAILBEND_DOWNLOAD_DIR=dl)
    check("an existing file is never replaced", c != 0 and "already exists" in r.get("error", "")
          and pathlib.Path(saved).read_bytes() == b"kept", r)


def download_names(srv, dl):
    named = []
    for index, filename, expected in [(1, "", "evil.sh"), (0, "/etc/passwd", "passwd"), (2, "", "gpj.exe"),
                                      (3, "", "hidden"), (0, "..\\..\\.profile", "profile")]:
        args = {"uid": FILES_UID, "index": index, "filename": filename} if filename else {"uid": FILES_UID, "index": index}
        c, r = tool(srv, "mail_get_attachment", args, MAILBEND_DOWNLOAD_DIR=dl)
        if not (c == 0 and r.get("filename") == expected and os.path.isfile(os.path.join(dl, expected))):
            named.append((index, filename, r))
    check("file names keep only their last component, without format characters or leading dots", not named
          and sorted(os.listdir(dl)) == ["all.bin", "evil.sh", "gpj.exe", "hidden", "passwd", "profile"], named)


def download_directories(srv, root):
    attach = os.path.join(root, "attach")
    os.makedirs(os.path.join(attach, "inside"))
    os.symlink(attach, os.path.join(root, "attach-alias"))
    overlapping = []
    for directory in (attach, os.path.join(attach, "inside"), os.path.join(root, "attach-alias")):
        c, r = get_attachment(srv, 0, MAILBEND_DOWNLOAD_DIR=directory, MAILBEND_ATTACH_DIR=attach)
        if not (c != 0 and "separate directories" in r.get("error", "")):
            overlapping.append((directory, r))
    check("a download directory equal to, inside, or an alias of MAILBEND_ATTACH_DIR is refused", not overlapping
          and os.listdir(attach) == ["inside"] and not os.listdir(os.path.join(attach, "inside")), overlapping)

    config = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, ".config")
    made_config = not os.path.isdir(config)
    in_config = None
    autostart = os.path.join(root, "x", "autostart")
    os.makedirs(autostart)
    in_ssh = os.path.join(root, "y", ".ssh")
    os.makedirs(in_ssh)
    bindir = os.path.join(root, "bin-dir")
    os.makedirs(bindir)
    os.symlink(bindir, os.path.join(root, "bin-alias"))
    path = os.environ.get("PATH", "")
    try:
        os.makedirs(config, exist_ok=True)
        in_config = tempfile.mkdtemp(prefix="mailbend-e2e-", dir=config)
        runnable = []
        for directory, reason, env in [
                (in_config, ".config", {}), (autostart, "autostart", {}), (in_ssh, ".ssh", {}),
                (bindir, "PATH", {"PATH": f"{bindir}:{path}"}),
                (bindir, "PATH", {"PATH": f"{os.path.join(root, 'bin-alias')}:{path}"}),
                (os.path.join(root, "bin-alias"), "PATH", {"PATH": f"{bindir}:{path}"})]:
            c, r = get_attachment(srv, 0, MAILBEND_DOWNLOAD_DIR=directory, **env)
            if not (c != 0 and reason in r.get("error", "") and not os.listdir(directory)):
                runnable.append((directory, reason, r))
        check("directories whose files may be run, or inside .ssh, are refused "
              "(~/.config, autostart, .ssh, PATH and its aliases)", not runnable, runnable)
    finally:
        if in_config:
            shutil.rmtree(in_config, ignore_errors=True)
        if made_config and os.path.isdir(config):
            os.rmdir(config)


def helper_fds(pid):
    fd_dir = f"/proc/{pid}/fd"
    links = []
    for fd in os.listdir(fd_dir):
        try:
            links.append(os.readlink(os.path.join(fd_dir, fd)))
        except OSError:
            pass
    return links


def killed_download(root):
    dl = os.path.join(root, "killed")
    os.makedirs(dl)
    helper = subprocess.Popen([str(ROOT / "bin" / "mailbend-attach"), "save", "", dl, "partial.bin", "1000",
                               os.environ.get("PATH", "")], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, env={**os.environ, "MAILBEND_APP_PASSWORD": PASSWORD})
    try:
        helper.stdin.write(b"partial data")
        helper.stdin.flush()
        deadline = time.monotonic() + 10
        writing = False
        while not writing and time.monotonic() < deadline and helper.poll() is None:
            writing = any(link.startswith(dl + "/") for link in helper_fds(helper.pid))
            if not writing:
                time.sleep(0.05)
        environ = pathlib.Path(f"/proc/{helper.pid}/environ").read_bytes() if writing else b"?"
        check("the save helper holds an unnamed file while it writes, with no MAILBEND_APP_PASSWORD in its environment",
              writing and b"MAILBEND_APP_PASSWORD" not in environ and PASSWORD.encode() not in environ, environ[:200])
    finally:
        helper.send_signal(signal.SIGKILL)
        helper.wait()
        helper.stdin.close()
    check("a helper killed mid-write leaves no file behind", os.listdir(dl) == [], os.listdir(dl))


def thread_message(uid, internaldate, headers, sender="alice@example.com", flags=()):
    return {"uid": uid, "flags": list(flags), "internaldate": internaldate,
            "raw": headers + f"From: {sender}\r\nTo: tester@example.com\r\nSubject: Trip plans\r\n"
                   "Content-Type: text/plain\r\n\r\nText.\r\n"}


def thread_fixture():
    """A thread across INBOX and Sent: Alice's message (INBOX 7), my reply
    (Sent 1, dated in another zone), her answer (INBOX 8), which names only my
    reply, and an answer to hers (INBOX 12), which names only hers. Beside
    them: a message with the same subject and no link (9), one whose
    References differ from the first message's ID only in case (10: a HEADER
    search matches it, the exact comparison does not), and a deleted reply
    (11)."""
    fixture = copy.deepcopy(FIX)
    fixture["mailboxes"]["INBOX"]["messages"] += [
        thread_message(7, "01-Oct-2026 09:00:00 +0000", "Message-ID: <trip1@example.com>\r\n"),
        thread_message(8, "01-Oct-2026 11:00:00 +0000",
                       "Message-ID: <trip3@example.com>\r\nIn-Reply-To: <trip2@example.com>\r\n"
                       "References: <trip2@example.com>\r\n"),
        thread_message(9, "01-Oct-2026 12:00:00 +0000", "Message-ID: <other@example.com>\r\n"),
        thread_message(10, "01-Oct-2026 12:30:00 +0000",
                       "Message-ID: <case@example.com>\r\nReferences: <TRIP1@EXAMPLE.COM>\r\n"),
        thread_message(11, "01-Oct-2026 13:00:00 +0000",
                       "Message-ID: <gone@example.com>\r\nIn-Reply-To: <trip1@example.com>\r\n",
                       flags=["\\Deleted"]),
        thread_message(12, "01-Oct-2026 14:00:00 +0000",
                       "Message-ID: <trip4@example.com>\r\nReferences: <trip3@example.com>\r\n"),
    ]
    fixture["mailboxes"]["Sent Messages"]["messages"] = [
        thread_message(1, "01-Oct-2026 12:00:00 +0200",
                       "Message-ID: <trip2@example.com>\r\nIn-Reply-To: <trip1@example.com>\r\n"
                       "References: <trip1@example.com>\r\n", sender="tester@example.com"),
    ]
    return fixture


def long_references_fixture(junk):
    """Alice's message (INBOX 7) and a reply to it (INBOX 8) whose References
    name `junk` IDs that no message has before hers."""
    refs = " ".join(f"<junk{i}@example.com>" for i in range(junk))
    fixture = copy.deepcopy(FIX)
    fixture["mailboxes"]["INBOX"]["messages"] += [
        thread_message(7, "01-Oct-2026 09:00:00 +0000", "Message-ID: <trip1@example.com>\r\n"),
        thread_message(8, "01-Oct-2026 10:00:00 +0000",
                       "Message-ID: <long@example.com>\r\nIn-Reply-To: <trip1@example.com>\r\n"
                       f"References: {refs} <trip1@example.com>\r\n"),
    ]
    return fixture


def thread_of(r):
    return [(m.get("folder"), m.get("uid"), m.get("parent")) for m in r.get("messages", [])]


def fetched_uids(line):
    return line.split(" UID FETCH ")[1].split(" ")[0].split(",")


def threads(work):
    first = ("INBOX", 7, None)
    reply = ("Sent Messages", 1, "<trip1@example.com>")
    answer = ("INBOX", 8, "<trip2@example.com>")
    fourth = ("INBOX", 12, "<trip3@example.com>")
    srv = Server(work, fixture=thread_fixture())
    try:
        before, log_start = srv.st(), len(srv.log_lines())
        c, r = tool(srv, "mail_get_thread", {"uid": 7})
        check("thread: from the first message, two rounds reach the reply in Sent and the answer to it, "
              "oldest first, and stop before INBOX 12",
              c == 0 and thread_of(r) == [first, reply, answer], r)
        check("thread: the folders searched and each message's uidvalidity are reported",
              r.get("searched") == ["INBOX", "Sent Messages"] and r.get("folder") == "INBOX" and r.get("uid") == 7
              and [m.get("uidvalidity") for m in r.get("messages", [])] == [1700000001, 1700000004, 1700000001], r)
        check("thread: each message carries its summary",
              [m.get("subject") for m in r.get("messages", [])] == ["Trip plans"] * 3
              and r["messages"][1].get("message_id") == "<trip2@example.com>", r)
        c, r = tool(srv, "mail_get_thread", {"uid": 8})
        check("thread: from a later message, its ancestors and the answer to it are found",
              c == 0 and thread_of(r) == [first, reply, answer, fourth], r)
        c, r = tool(srv, "mail_get_thread", {"uid": 9})
        check("thread: a message with no links is its own thread, whatever its subject",
              c == 0 and thread_of(r) == [("INBOX", 9, None)], r)
        c, r = tool(srv, "mail_get_thread", {"folder": "Sent Messages", "uid": 1}, MAILBEND_READ_ONLY="1")
        check("thread: allowed in read-only mode; from Sent, INBOX is searched too, so the message it answers "
              "and the answers to it are found",
              c == 0 and r.get("searched") == ["Sent Messages", "INBOX"]
              and thread_of(r) == [first, reply, answer, fourth], r)
        c, r = tool(srv, "mail_get_thread", {"uid": 99})
        check("thread: a missing UID is an error", c != 0 and "no message with UID 99" in r.get("error", ""), r)
        log = srv.log_lines()[log_start:]
        searches = [line for line in log if " UID SEARCH " in line]
        check("thread: every search is a HEADER search of undeleted messages",
              searches and all(" HEADER " in line and line.endswith(" UNDELETED") for line in searches), searches[:3])
        check("thread: a message that matches a search only by case is fetched (the exact lists above leave it out)",
              any("10" in fetched_uids(line) for line in log if " UID FETCH " in line), log)
        check("thread: reads change nothing (EXAMINE only, no flag stored)",
              srv.st() == before and not any(" SELECT " in line or " STORE " in line for line in log), log)
    finally:
        srv.stop()
    srv = Server(work, fixture=long_references_fixture(3000))
    try:
        log_start = len(srv.log_lines())
        c, r = tool(srv, "mail_get_thread", {"uid": 7})
        searches = [line for line in srv.log_lines()[log_start:] if " UID SEARCH " in line]
        check("thread: a reply naming 3000 unknown IDs in References is read; its round searches only 50 IDs "
              "(3 keys in 2 folders each), after 1 in the first round",
              c == 0 and thread_of(r) == [first, ("INBOX", 8, "<trip1@example.com>")]
              and len(searches) == (1 + 50) * 3 * 2, (r, len(searches)))
    finally:
        srv.stop()


if __name__ == "__main__":
    main()
