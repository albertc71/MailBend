"""Permanent deletes on Gmail, using only fake mail.

Gmail shows labels as folders. Its expunge destroys a message only in Trash
or Spam; anywhere else it removes that label, and the message stays in All
Mail. The fake server acts so when it advertises X-GM-EXT-1.
"""
import copy

GMAIL_CAPS = "MOVE,UIDPLUS,SPECIAL-USE,X-GM-EXT-1"
CONFIRM = "permanently-delete"
ALL_MAIL = "[Gmail]/All Mail"


def gmail_fixture(t):
    fixture = copy.deepcopy(t.FIX)
    inbox = fixture["mailboxes"]["INBOX"]
    message = dict(inbox["messages"][0], uid=1)
    fixture["mailboxes"] = {
        "INBOX": inbox,
        "Receipts": {"uidvalidity": 11, "messages": [message]},
        ALL_MAIL: {"uidvalidity": 12, "special": ["\\All"], "messages": []},
        "[Gmail]/Trash": {"uidvalidity": 13, "special": ["\\Trash"], "messages": [message]},
        "[Gmail]/Spam": {"uidvalidity": 14, "special": ["\\Junk"], "messages": [message]},
    }
    return fixture


def delete(t, srv, folder, uidvalidity, dry_run=False):
    """Deletes UID 1 of `folder`; returns the exit code, the result and the
    IMAP lines the call sent."""
    start = len(srv.log_lines())
    code, result = t.tool(srv, "mail_delete", {"folder": folder, "uids": [1], "uidvalidity": uidvalidity,
                                               "confirm": CONFIRM, "dry_run": dry_run})
    return code, result, srv.log_lines()[start:]


def changes(t, lines):
    return [line for line in lines if any(cmd in line for cmd in t.MUTATING_COMMANDS + (" SELECT ",))]


def refusals(t, work):
    srv = t.Server(work, caps=GMAIL_CAPS, fixture=gmail_fixture(t))
    try:
        for folder, uidvalidity, dry_run in [("INBOX", 1700000001, False), ("INBOX", 1700000001, True),
                                             ("Receipts", 11, False)]:
            before = srv.st()["mailboxes"]
            code, result, lines = delete(t, srv, folder, uidvalidity, dry_run)
            after = srv.st()["mailboxes"]
            t.check(f"gmail: delete in {folder} (dry run {dry_run}) refuses before any change",
                    code != 0 and "mail_trash" in result.get("error", "") and not changes(t, lines)
                    and after == before,
                    {"result": result, "changes": changes(t, lines), "all_mail": after[ALL_MAIL]["messages"]})
    finally:
        srv.stop()


def trash_and_spam(t, work):
    srv = t.Server(work, caps=GMAIL_CAPS, fixture=gmail_fixture(t))
    try:
        before = srv.st()["mailboxes"]
        code, result, lines = delete(t, srv, "[Gmail]/Spam", 14, dry_run=True)
        t.check("gmail: a dry run in Spam previews the delete",
                code == 0 and t.dry_run_preview(result, "UID EXPUNGE 1") and not changes(t, lines)
                and srv.st()["mailboxes"] == before, result)
        code, result, lines = delete(t, srv, "[Gmail]/Trash", 13)
        after = srv.st()["mailboxes"]
        t.check("gmail: delete in Trash expunges that UID for good",
                code == 0 and result.get("permanently_deleted") is True
                and any(line.endswith("UID EXPUNGE 1") for line in lines)
                and not after["[Gmail]/Trash"]["messages"] and not after[ALL_MAIL]["messages"], result)
    finally:
        srv.stop()


def other_servers(t, work):
    srv = t.Server(work, caps="MOVE,UIDPLUS,SPECIAL-USE", fixture=gmail_fixture(t))
    try:
        code, result, lines = delete(t, srv, "INBOX", 1700000001)
        t.check("gmail: without X-GM-EXT-1 a delete in INBOX still expunges",
                code == 0 and result.get("permanently_deleted") is True
                and any(line.endswith("UID EXPUNGE 1") for line in lines)
                and 1 not in t.msgs(srv.st(), "INBOX"), result)
    finally:
        srv.stop()


def run(t, work):
    refusals(t, work)
    trash_and_spam(t, work)
    other_servers(t, work)
