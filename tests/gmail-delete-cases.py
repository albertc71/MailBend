"""Permanent deletes on Gmail, using only fake mail.

Gmail shows labels as folders, and its expunge surely destroys a message
only in Trash or Spam. Anywhere else mail_delete must refuse before any
change.
"""
import copy

# Gmail puts the role attributes on every LIST response, so the cases do not
# lean on SPECIAL-USE.
GMAIL_CAPS = "MOVE,UIDPLUS,X-GM-EXT-1"
CONFIRM = "permanently-delete"
ALL_MAIL = "[Gmail]/All Mail"
TRASH = "[Gmail]/Trash"
REVIEW = "To Delete"
REVIEWED = {"uid": 1, "flags": [], "internaldate": "01-Oct-2026 09:00:00 +0000",
            "raw": "Message-ID: <reviewed1@example.com>\r\nFrom: dana@example.com\r\nTo: tester@example.com\r\n"
                   "Subject: Reviewed for deletion\r\n\r\nNo longer needed.\r\n"}


def gmail_fixture(t):
    fixture = copy.deepcopy(t.FIX)
    inbox = fixture["mailboxes"]["INBOX"]
    message = dict(inbox["messages"][0], uid=1)
    fixture["mailboxes"] = {
        "INBOX": inbox,
        "Receipts": {"uidvalidity": 11, "messages": [message]},
        ALL_MAIL: {"uidvalidity": 12, "special": ["\\All"], "messages": []},
        TRASH: {"uidvalidity": 13, "special": ["\\Trash"], "messages": [message]},
        "[Gmail]/Spam": {"uidvalidity": 14, "special": ["\\Junk"], "messages": [message]},
        REVIEW: {"uidvalidity": 15, "messages": [REVIEWED]},
    }
    return fixture


def delete(t, srv, folder, uidvalidity, uid=1, dry_run=False, **env):
    """Deletes `uid` of `folder`; returns the exit code, the result and the
    IMAP lines the call sent."""
    start = len(srv.log_lines())
    code, result = t.tool(srv, "mail_delete", {"folder": folder, "uids": [uid], "uidvalidity": uidvalidity,
                                               "confirm": CONFIRM, "dry_run": dry_run}, **env)
    return code, result, srv.log_lines()[start:]


def changes(t, lines):
    return [line for line in lines if any(cmd in line for cmd in t.MUTATING_COMMANDS + (" SELECT ",))]


def refusal(t, srv, folder, uidvalidity, **kwargs):
    """Deletes UID 1 of `folder`. Returns the error when the call refused
    before any change (else None), and what the call did."""
    before = srv.st()["mailboxes"]
    code, result, lines = delete(t, srv, folder, uidvalidity, **kwargs)
    refused = code != 0 and not changes(t, lines) and srv.st()["mailboxes"] == before
    return (result.get("error", "") if refused else None), {"result": result, "changes": changes(t, lines)}


def refusals(t, work):
    srv = t.Server(work, caps=GMAIL_CAPS, fixture=gmail_fixture(t))
    try:
        for folder, uidvalidity, dry_run in [("INBOX", 1700000001, False), ("INBOX", 1700000001, True),
                                             ("Receipts", 11, False)]:
            error, did = refusal(t, srv, folder, uidvalidity, dry_run=dry_run)
            t.check(f"gmail: delete in {folder} (dry run {dry_run}) refuses before any change",
                    "mail_trash" in (error or ""), did)
    finally:
        srv.stop()


def conflicting_rows(t, work):
    for order, rows in [("first", [["\\Trash"], []]), ("second", [[], ["\\Trash"]])]:
        fixture = gmail_fixture(t)
        fixture["list_rows"] = {"Receipts": rows}
        srv = t.Server(work, caps=GMAIL_CAPS, fixture=fixture)
        try:
            error, did = refusal(t, srv, "Receipts", 11)
            t.check(f"gmail: a folder listed twice, the \\Trash row {order}, refuses a delete before any change",
                    "mail_trash" in (error or ""), did)
        finally:
            srv.stop()


def review_route(t, work):
    srv = t.Server(work, caps=GMAIL_CAPS, fixture=gmail_fixture(t))
    try:
        error, did = refusal(t, srv, REVIEW, 15)
        t.check(f"gmail: delete in {REVIEW} refuses before any change and points to mail_move",
                "mail_move" in (error or ""), did)
        moved, out = t.tool(srv, "mail_move", {"folder": REVIEW, "uids": [1], "uidvalidity": 15,
                                               "destination": TRASH})
        searched, found = t.tool(srv, "mail_search", {"folder": TRASH})
        uids = [m["uid"] for m in found.get("messages", []) if m.get("subject") == "Reviewed for deletion"]
        code, result, lines = delete(t, srv, TRASH, found.get("uidvalidity", 0), uid=uids[0] if uids else 0)
        left = [name for name, mb in srv.st()["mailboxes"].items()
                if any(m["raw"] == REVIEWED["raw"] for m in mb["messages"])]
        t.check(f"gmail: mail_move from {REVIEW} into Trash, then mail_delete there, leaves the message "
                "in no folder", moved == 0 and searched == 0 and len(uids) == 1 and code == 0
                and result.get("permanently_deleted") is True and not left,
                {"move": out, "search": found, "delete": result, "left_in": left})
    finally:
        srv.stop()


def jev_not_asked(t, work):
    srv, ts = t.Server(work, caps=GMAIL_CAPS, fixture=gmail_fixture(t)), t.TypeSafe(work)
    try:
        error, did = refusal(t, srv, "INBOX", 1700000001, **t.jev_env(ts, t.typesafe_key_file(work)))
        t.check("gmail: with Jev on, a refused delete asks TypeSafe nothing",
                "mail_trash" in (error or "") and not ts.requests(), {**did, "typesafe": ts.requests()})
    finally:
        ts.stop()
        srv.stop()


def trash_and_spam(t, work):
    srv = t.Server(work, caps=GMAIL_CAPS, fixture=gmail_fixture(t))
    try:
        before = srv.st()["mailboxes"]
        code, result, lines = delete(t, srv, "[Gmail]/Spam", 14, dry_run=True)
        t.check("gmail: a dry run in Spam previews the delete",
                code == 0 and t.dry_run_preview(result, "UID EXPUNGE 1") and not changes(t, lines)
                and srv.st()["mailboxes"] == before, result)
        code, result, lines = delete(t, srv, TRASH, 13)
        after = srv.st()["mailboxes"]
        t.check("gmail: delete in Trash expunges that UID for good",
                code == 0 and result.get("permanently_deleted") is True
                and any(line.endswith("UID EXPUNGE 1") for line in lines)
                and not after[TRASH]["messages"], result)
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
    conflicting_rows(t, work)
    review_route(t, work)
    jev_not_asked(t, work)
    trash_and_spam(t, work)
    other_servers(t, work)
