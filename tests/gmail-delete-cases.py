"""Permanent deletes on Gmail, and what refused deletes advise, using only
fake mail.

Gmail shows labels as folders, and its expunge surely destroys a message
only in Trash or Spam. Anywhere else mail_delete must refuse before any
change. A refusal says why, and every call it names must be one MailBend
accepts.
"""
import copy
import re

# Gmail puts the role attributes on every LIST response, so the cases do not
# lean on SPECIAL-USE.
GMAIL_CAPS = "MOVE,UIDPLUS,X-GM-EXT-1"
CONFIRM = "permanently-delete"
TRASH = "[Gmail]/Trash"
REVIEW = "To Delete"
GMAIL_REFUSAL = "on Gmail a permanent delete is certain only in Trash or Spam"
REVIEW_REFUSAL = f'mail_trash never moves mail into or out of "{REVIEW}", which the user reviews'
NO_TRASH = "there is no single Trash mailbox MailBend may move mail into on this server"
LUNCH = "Lunch tomorrow?"
REVIEWED = "Reviewed for deletion"
TRASH_OVERRIDE = {"MAILBEND_TRASH_FOLDER": "Receipts"}
# The calls a refused Gmail delete names when the server has one Trash
# mailbox to move the messages into.
ROUTE = ["mail_move", "mail_search", "mail_delete"]
# How a refusal names a call ("with mail_x", "run mail_x" or "mail_x can"),
# and the folders it names for a move and for a delete.
NAMED_CALL = re.compile(r'\b(?:with|run) (mail_\w+)|\b(mail_\w+) can\b')
MOVE_INTO = re.compile(r'into "([^"]+)" with mail_move')
DELETE_IN = re.compile(r'mail_delete in "([^"]+)"')


def note(name, subject):
    return {"uid": 1, "flags": [], "internaldate": "01-Oct-2026 09:00:00 +0000",
            "raw": f"Message-ID: <{name}@example.com>\r\nFrom: dana@example.com\r\nTo: tester@example.com\r\n"
                   f"Subject: {subject}\r\n\r\nNo longer needed.\r\n"}


def gmail_fixture(t):
    fixture = copy.deepcopy(t.FIX)
    inbox = fixture["mailboxes"]["INBOX"]
    message = dict(inbox["messages"][0], uid=1)
    fixture["mailboxes"] = {
        "INBOX": inbox,
        "Receipts": {"uidvalidity": 11, "messages": [message]},
        TRASH: {"uidvalidity": 13, "special": ["\\Trash"], "messages": [note("trashed1", "Old newsletter")]},
        "[Gmail]/Spam": {"uidvalidity": 14, "special": ["\\Junk"], "messages": [message]},
        REVIEW: {"uidvalidity": 15, "messages": [note("reviewed1", REVIEWED)]},
    }
    return fixture


def gmail_with(t, specials):
    """The Gmail fixture, with the attributes of the mailboxes in `specials`
    replaced."""
    fixture = gmail_fixture(t)
    for name, special in specials.items():
        fixture["mailboxes"][name]["special"] = special
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
    """Makes the calls `advice` names, in its order, for UID 1 of `folder`,
    titled `subject`, as an agent reading it literally would. A move goes
    into the folder the advice names, a search looks where the message now
    is, and a delete runs in the folder the advice names, on the UIDs the
    last search found. Returns each call's name, exit code and result."""
    move_into, delete_in = MOVE_INTO.search(advice), DELETE_IN.search(advice)
    calls, uids = [], [1]
    for match in NAMED_CALL.finditer(advice):
        name = match[1] or match[2]
        args = {"folder": folder, "uids": uids, "uidvalidity": uidvalidity}
        if name == "mail_move":
            args["destination"] = move_into and move_into[1]
            folder = args["destination"]
        elif name == "mail_search":
            args = {"folder": folder}
        elif name == "mail_delete":
            args.update(folder=delete_in and delete_in[1], confirm=CONFIRM)
        code, result = t.tool(srv, name, args, **env)
        calls.append((name, code, result))
        if name == "mail_search":
            uids = [m["uid"] for m in result.get("messages", []) if m.get("subject") == subject]
            uidvalidity = result.get("uidvalidity", 0)
    return calls


def advice_followed(t, work, caps, fixture, name, folder, uidvalidity, subject, **env):
    """Calls `name` on UID 1 of `folder`, then follows the advice of its
    refusal. Returns the refusal (None unless it refused before any change)
    and the calls it named."""
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


def check_advice(t, work, title, caps, fixture, name, folder, uidvalidity, subject, reason, named, **env):
    """Checks that `name` on UID 1 of `folder` refuses before any change,
    says `reason` and names exactly the calls `named`, and that those calls
    are accepted and delete the message for good."""
    error, calls = advice_followed(t, work, caps, fixture, name, folder, uidvalidity, subject, **env)
    outcome = f"names {', '.join(named)}, and they delete it for good" if named else "says why and names no call"
    t.check(f"{title} refuses before any change, {outcome}",
            error is not None and reason in error and [call for call, _, _ in calls] == named
            and (not named or deleted_by(calls)), {"error": error, "calls": calls})


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


def gmail_advice(t, work):
    for title, fixture, name, folder, uidvalidity, subject, reason, named, env in [
        ("delete in INBOX", gmail_fixture(t), "mail_delete", "INBOX", 1700000001, LUNCH, GMAIL_REFUSAL, ROUTE,
         {}),
        (f"delete in {REVIEW}", gmail_fixture(t), "mail_delete", REVIEW, 15, REVIEWED, GMAIL_REFUSAL, ROUTE, {}),
        ("with Receipts as the trash folder, delete in Receipts", gmail_fixture(t), "mail_delete", "Receipts", 11,
         LUNCH, GMAIL_REFUSAL, ROUTE, TRASH_OVERRIDE),
        (f"mail_trash in {REVIEW}", gmail_fixture(t), "mail_trash", REVIEW, 15, REVIEWED, REVIEW_REFUSAL, [], {}),
        ("with Receipts as the trash folder, mail_trash in Receipts", gmail_fixture(t), "mail_trash", "Receipts",
         11, LUNCH, 'already in the trash folder "Receipts"; nothing was changed', [], TRASH_OVERRIDE),
        ("with two mailboxes listed as \\Trash, delete in INBOX", gmail_with(t, {"Receipts": ["\\Trash"]}),
         "mail_delete", "INBOX", 1700000001, LUNCH, NO_TRASH, [], {}),
        (f"with {TRASH} unselectable, delete in INBOX", gmail_with(t, {TRASH: ["\\Trash", "\\Noselect"]}),
         "mail_delete", "INBOX", 1700000001, LUNCH, NO_TRASH, [], {}),
        (f"with {REVIEW} the only folder listed as \\Trash, delete in INBOX",
         gmail_with(t, {TRASH: [], REVIEW: ["\\Trash"]}), "mail_delete", "INBOX", 1700000001, LUNCH, NO_TRASH, [], {}),
    ]:
        check_advice(t, work, f"gmail: {title}", GMAIL_CAPS, fixture, name, folder, uidvalidity, subject, reason,
                     named, **env)


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
    fixture["mailboxes"][REVIEW] = {"uidvalidity": 15, "messages": [note("reviewed1", REVIEWED)]}
    check_advice(t, work, f"delete advice: without MOVE or UIDPLUS, mail_trash in {REVIEW}", "SPECIAL-USE", fixture,
                 "mail_trash", REVIEW, 15, REVIEWED, REVIEW_REFUSAL, [])
    fixture = copy.deepcopy(t.FIX)
    del fixture["mailboxes"]["Deleted Messages"]
    fixture["mailboxes"][REVIEW] = {"uidvalidity": 15, "special": ["\\Trash"], "messages": []}
    check_advice(t, work, f"delete advice: with {REVIEW} listed as \\Trash, mail_trash in INBOX", None, fixture,
                 "mail_trash", "INBOX", 1700000001, LUNCH, REVIEW_REFUSAL, [])


def run(t, work):
    refusals(t, work)
    conflicting_rows(t, work)
    gmail_advice(t, work)
    jev_not_asked(t, work)
    trash_and_spam(t, work)
    other_servers(t, work)
    other_server_advice(t, work)
