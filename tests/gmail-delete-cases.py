"""Permanent deletes on Gmail, and the advice refused deletes give, using
only fake mail.

Gmail shows labels as folders, and its expunge surely destroys a message
only in Trash or Spam. Anywhere else mail_delete must refuse before any
change. Every call a refusal advises must then be one MailBend accepts.
"""
import copy
import re

# Gmail puts the role attributes on every LIST response, so the cases do not
# lean on SPECIAL-USE.
GMAIL_CAPS = "MOVE,UIDPLUS,X-GM-EXT-1"
CONFIRM = "permanently-delete"
ALL_MAIL = "[Gmail]/All Mail"
TRASH = "[Gmail]/Trash"
REVIEW = "To Delete"
GMAIL_REFUSAL = "on Gmail a permanent delete is certain only in Trash or Spam"
LUNCH = "Lunch tomorrow?"
TRASH_OVERRIDE = {"MAILBEND_TRASH_FOLDER": "Receipts"}
# How a refusal names its next call: a move into a folder, and a delete in
# one. A folder name is quoted, or a bare word.
ADVISED_MOVE = re.compile(r'into "?([^"]+?)"? with mail_move')
ADVISED_DELETE = re.compile(r'mail_delete in ("[^"]+"|\S+)')


def note(name, subject):
    return {"uid": 1, "flags": [], "internaldate": "01-Oct-2026 09:00:00 +0000",
            "raw": f"Message-ID: <{name}@example.com>\r\nFrom: dana@example.com\r\nTo: tester@example.com\r\n"
                   f"Subject: {subject}\r\n\r\nNo longer needed.\r\n"}


REVIEWED = note("reviewed1", "Reviewed for deletion")


def gmail_fixture(t):
    fixture = copy.deepcopy(t.FIX)
    inbox = fixture["mailboxes"]["INBOX"]
    message = dict(inbox["messages"][0], uid=1)
    fixture["mailboxes"] = {
        "INBOX": inbox,
        "Receipts": {"uidvalidity": 11, "messages": [message]},
        # Gmail shows a message under each of its labels and in All Mail.
        ALL_MAIL: {"uidvalidity": 12, "special": ["\\All"], "messages": [REVIEWED]},
        TRASH: {"uidvalidity": 13, "special": ["\\Trash"], "messages": [note("trashed1", "Old newsletter")]},
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


def follow(t, srv, advice, folder, uidvalidity, subject, **env):
    """Makes the calls `advice` names for UID 1 of `folder`, titled `subject`,
    as an agent reading it literally would: the move it names, then a search
    and the delete in the folder it names. Returns each call's name, exit
    code and result."""
    calls = []
    move, delete_in = ADVISED_MOVE.search(advice), ADVISED_DELETE.search(advice)
    if move:
        calls.append(("mail_move", *t.tool(srv, "mail_move", {"folder": folder, "uids": [1], "uidvalidity": uidvalidity,
                                                             "destination": move.group(1)}, **env)))
    if delete_in:
        target = delete_in.group(1).strip('".,;')
        code, found = t.tool(srv, "mail_search", {"folder": target}, **env)
        calls.append(("mail_search", code, found))
        uids = [m["uid"] for m in found.get("messages", []) if m.get("subject") == subject]
        calls.append(("mail_delete", *t.tool(srv, "mail_delete", {
            "folder": target, "uids": uids if len(uids) == 1 else [], "uidvalidity": found.get("uidvalidity", 0),
            "confirm": CONFIRM}, **env)))
    return calls


def advice_followed(t, work, caps, fixture, name, folder, uidvalidity, subject, **env):
    """Calls `name` on UID 1 of `folder`, then follows the advice of its
    refusal. Returns the refusal (None unless it refused before any change)
    and the advised calls."""
    srv = t.Server(work, caps=caps, fixture=fixture)
    try:
        before = srv.st()["mailboxes"]
        args = {"folder": folder, "uids": [1], "uidvalidity": uidvalidity}
        code, result = t.tool(srv, name, {**args, "confirm": CONFIRM} if name == "mail_delete" else args, **env)
        error = result.get("error", "") if code != 0 and srv.st()["mailboxes"] == before else None
        return error, follow(t, srv, error or "", folder, uidvalidity, subject, **env)
    finally:
        srv.stop()


def deleted_by(calls):
    """Whether every call was accepted and the last deleted for good."""
    return bool(calls) and all(code == 0 for _, code, _ in calls) and calls[-1][2].get("permanently_deleted") is True


def refusals(t, work):
    srv = t.Server(work, caps=GMAIL_CAPS, fixture=gmail_fixture(t))
    try:
        for folder, uidvalidity, dry_run in [("INBOX", 1700000001, False), ("INBOX", 1700000001, True),
                                             ("Receipts", 11, False)]:
            error, did = refusal(t, srv, folder, uidvalidity, dry_run=dry_run)
            t.check(f"gmail: delete in {folder} (dry run {dry_run}) refuses before any change",
                    GMAIL_REFUSAL in (error or ""), did)
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
                    GMAIL_REFUSAL in (error or ""), did)
        finally:
            srv.stop()


def advised_routes(t, work):
    for title, name, folder, uidvalidity, subject, env in [
        ("delete in INBOX", "mail_delete", "INBOX", 1700000001, LUNCH, {}),
        (f"delete in {REVIEW}", "mail_delete", REVIEW, 15, "Reviewed for deletion", {}),
        (f"mail_trash in {REVIEW}", "mail_trash", REVIEW, 15, "Reviewed for deletion", {}),
        ("with Receipts as the trash folder, delete in Receipts", "mail_delete", "Receipts", 11, LUNCH,
         TRASH_OVERRIDE),
        ("with Receipts as the trash folder, mail_trash in Receipts", "mail_trash", "Receipts", 11, LUNCH,
         TRASH_OVERRIDE),
        (f"with Receipts as the trash folder, mail_trash in {REVIEW}", "mail_trash", REVIEW, 15,
         "Reviewed for deletion", TRASH_OVERRIDE),
    ]:
        error, calls = advice_followed(t, work, GMAIL_CAPS, gmail_fixture(t), name, folder, uidvalidity, subject,
                                       **env)
        t.check(f"gmail: {title} refuses before any change, and every call it advises is accepted and ends "
                "in a permanent delete", error is not None and deleted_by(calls), {"error": error, "calls": calls})


def jev_not_asked(t, work):
    srv, ts = t.Server(work, caps=GMAIL_CAPS, fixture=gmail_fixture(t)), t.TypeSafe(work)
    try:
        error, did = refusal(t, srv, "INBOX", 1700000001, **t.jev_env(ts, t.typesafe_key_file(work)))
        t.check("gmail: with Jev on, a refused delete asks TypeSafe nothing",
                GMAIL_REFUSAL in (error or "") and not ts.requests(), {**did, "typesafe": ts.requests()})
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


def other_server_advice(t, work):
    fixture = copy.deepcopy(t.FIX)
    fixture["mailboxes"]["Trash"] = fixture["mailboxes"].pop("Deleted Messages")
    fixture["mailboxes"][REVIEW] = {"uidvalidity": 15, "messages": [REVIEWED]}
    error, calls = advice_followed(t, work, "MOVE,SPECIAL-USE", fixture, "mail_trash", REVIEW, 15,
                                   "Reviewed for deletion")
    t.check(f"delete advice: without UIDPLUS, mail_trash in {REVIEW} refuses, advises no call and says "
            "mail_delete needs UIDPLUS", error is not None and not calls and "UIDPLUS" in error,
            {"error": error, "calls": calls})
    fixture = copy.deepcopy(t.FIX)
    del fixture["mailboxes"]["Deleted Messages"]
    fixture["mailboxes"][REVIEW] = {"uidvalidity": 15, "special": ["\\Trash"], "messages": []}
    error, calls = advice_followed(t, work, None, fixture, "mail_trash", "INBOX", 1700000001, LUNCH)
    t.check(f"delete advice: with {REVIEW} listed as \\Trash, mail_trash in INBOX refuses, and every call it "
            "advises is accepted and ends in a permanent delete", error is not None and deleted_by(calls),
            {"error": error, "calls": calls})


def run(t, work):
    refusals(t, work)
    conflicting_rows(t, work)
    advised_routes(t, work)
    jev_not_asked(t, work)
    trash_and_spam(t, work)
    other_servers(t, work)
    other_server_advice(t, work)
