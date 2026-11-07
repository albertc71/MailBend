"""Accepted reply follow-ups through public CLI/MCP, with synthetic mail only."""
import copy
from pathlib import Path


def arguments(t, **over):
    return {"uid": 1, "uidvalidity": t.INBOX_VALIDITY, "body": "Synthetic answer",
            "mark_answered": True, **over}


def stores(srv):
    return [line.split(" ", 1)[1] for line in srv.log_lines() if " STORE " in line]


def no_status(result):
    return "original_marked" not in result and "original_mark_reason" not in result


def exclusions(t, work):
    for label, args, env, accepted in [
        ("default", {"uid": 1, "uidvalidity": t.INBOX_VALIDITY, "body": "Synthetic answer"}, {}, True),
        ("explicit false", arguments(t, mark_answered=False), {}, True),
        ("draft", arguments(t, as_draft=True), {}, False),
        ("dry run", arguments(t, dry_run=True), {}, False),
        ("draft preview", arguments(t, as_draft=True, dry_run=True), {}, False),
        ("read only", arguments(t), {"MAILBEND_READ_ONLY": "1"}, False),
        ("drafts only", arguments(t), {"MAILBEND_DRAFTS_ONLY": "1"}, False),
        ("bad safety switch", arguments(t), {"MAILBEND_READ_ONLY": "invalid"}, False),
        ("recipient gate", arguments(t), {"MAILBEND_ALLOWED_RECIPIENTS": "nobody@example.invalid"}, False),
        ("stale original", arguments(t, uidvalidity=99), {}, False),
        ("missing original", arguments(t, uid=99), {}, False),
        ("malformed opt-in", arguments(t, mark_answered="true"), {}, False),
    ]:
        srv = t.Server(work)
        try:
            before = copy.deepcopy(srv.st()["mailboxes"]["INBOX"])
            c, result = t.tool(srv, "mail_reply", args, **env)
            t.check(f"reply marking {label}: no mark or misleading marking status",
                    no_status(result) and not stores(srv)
                    and srv.st()["mailboxes"]["INBOX"] == before
                    and len(srv.st()["sent"]) == int(accepted), result)
            t.check(f"reply marking {label}: the existing request outcome is preserved",
                    (c == 0) == (accepted or label in {"draft", "dry run", "draft preview"}), result)
            if accepted:
                t.check(f"reply marking {label}: existing send result remains successful",
                        c == 0 and result.get("smtp_outcome") == "accepted", result)
        finally:
            srv.stop()


def smtp_outcomes(t, work):
    for recipient, outcome, sent in [
        ("before-data-close@example.com", "not_sent", 0),
        ("reject@example.com", "not_sent", 0),
        ("final-reject@example.com", "not_sent", 0),
        ("lost-reply@example.com", "unknown", 1),
    ]:
        fixture = copy.deepcopy(t.FIX)
        fixture["mailboxes"]["INBOX"]["messages"][0]["raw"] = (
            f"From: {recipient}\r\nTo: tester@example.com\r\n"
            "Message-ID: <original@example.test>\r\nSubject: Synthetic\r\n\r\nHello\r\n")
        srv = t.Server(work, fixture=fixture)
        try:
            before = copy.deepcopy(srv.st()["mailboxes"])
            c, result = t.tool(srv, "mail_reply", arguments(t))
            t.check(f"reply marking SMTP {recipient}: no post-send mutation",
                    c != 0 and result.get("smtp_outcome") == outcome and no_status(result)
                    and not stores(srv) and srv.st()["mailboxes"] == before
                    and len(srv.st()["sent"]) == sent, result)
            t.check("reply marking: uncertain or refused SMTP is never repeated",
                    sum(line.startswith("MAIL FROM:") for line in srv.log_lines()) == 1)
        finally:
            srv.stop()


def followup_outcomes(t, work):
    for label, extra, expected, reason, stored in [
        ("selection refused", ["--reject", "SELECT"], False, "selection_refused", False),
        ("search refused", ["--reject", "SEARCH"], False, "search_refused", False),
        ("store reply lost", ["--drop-unanswered", "STORE"], "unverified", "mark_unverified", True),
        ("store acknowledged, readback lost", ["--drop-after", "STORE"], "unverified", "mark_unverified", True),
        ("valid empty flags", ["--permanent-flags", "\\Seen"], False, "answered_absent", False),
        ("missing flags", ["--fetch-no-flags", "1"], "unverified", "original_not_observed", True),
        ("malformed flags", ["--fetch-bad-flags", "1"], "unverified", "original_not_observed", True),
        ("only STORE has flags", ["--noisy-store", "--fetch-no-flags", "1"], "unverified", "original_not_observed", True),
        ("original vanished", ["--remove-after-fetch", "1"], "unverified", "original_not_observed", False),
        ("noisy valid readback", ["--noisy-store", "--flags-first"], True, "answered_observed", True),
    ]:
        fixture = copy.deepcopy(t.FIX)
        fixture["mailboxes"]["INBOX"]["messages"][0]["flags"] = []
        srv = t.Server(work, fixture=fixture, extra=extra)
        try:
            c, result = t.tool(srv, "mail_reply", arguments(t))
            t.check(f"reply marking {label}: accepted send and exact mark outcome",
                    c == 0 and result.get("smtp_outcome") == "accepted"
                    and result.get("original_marked") == expected
                    and result.get("original_mark_reason") == reason
                    and "Do not resend" in result.get("next_action", "")
                    and len(srv.st()["sent"]) == 1, result)
            original = t.msgs(srv.st(), "INBOX").get(1)
            t.check(f"reply marking {label}: observed fixture state matches the fault",
                    bool(original and "\\Answered" in original["flags"]) == stored)
            t.check(f"reply marking {label}: at most one exact store and no expunge",
                    stores(srv) in ([], ["UID STORE 1 +FLAGS.SILENT (\\Answered)"])
                    and not any("EXPUNGE" in line for line in srv.log_lines()))
        finally:
            srv.stop()


def sent_copy(t, work):
    for folder, expected in [("Sent Messages", "saved to"), ("Nowhere", "failed:")]:
        srv = t.Server(work, extra=["--cut-goodbye"] if folder == "Nowhere" else [])
        try:
            c, result = t.tool(srv, "mail_reply", arguments(t),
                               MAILBEND_SAVE_SENT="1", MAILBEND_SENT_FOLDER=folder)
            t.check(f"reply marking with {folder} filing: acceptance and marking are independent",
                    c == 0 and result.get("smtp_outcome") == "accepted"
                    and result.get("original_marked") is True
                    and result.get("sent_copy", "").startswith(expected)
                    and len(srv.st()["sent"]) == 1, result)
            copies = srv.st()["mailboxes"]["Sent Messages"]["messages"]
            t.check("reply marking: Sent copy is accounted for separately from original flags",
                    len(copies) == int(folder == "Sent Messages")
                    and "\\Answered" in t.flags(srv.st(), "INBOX", 1)
                    and stores(srv) == ["UID STORE 1 +FLAGS.SILENT (\\Answered)"])
        finally:
            srv.stop()


def identity(t, work):
    fixture = copy.deepcopy(t.FIX)
    original = copy.deepcopy(fixture["mailboxes"]["INBOX"]["messages"][0])
    original["uid"] = 7
    original["flags"] = []
    fixture["mailboxes"]["Original"] = {"uidvalidity": 91, "special": [], "messages": [original]}
    for reset in (False, True):
        current = copy.deepcopy(fixture)
        if reset:
            current["select_uidvalidity"] = {"Original": 92}
        srv = t.Server(work, fixture=current)
        try:
            inbox = copy.deepcopy(srv.st()["mailboxes"]["INBOX"])
            c, result = t.tool(srv, "mail_reply", arguments(t, folder="Original", uid=7, uidvalidity=91))
            t.check(f"reply marking identity reset={reset}: original identity remains pinned",
                    c == 0 and result.get("smtp_outcome") == "accepted"
                    and result.get("original_marked") is (not reset)
                    and result.get("original_mark_reason") == ("identity_changed" if reset else "answered_observed")
                    and srv.st()["mailboxes"]["INBOX"] == inbox and len(srv.st()["sent"]) == 1, result)
            t.check(f"reply marking identity reset={reset}: no widened or refreshed target",
                    stores(srv) == ([] if reset else ["UID STORE 7 +FLAGS.SILENT (\\Answered)"])
                    and [line.split(" ", 1)[1] for line in srv.log_lines() if " SELECT " in line]
                    == ['SELECT "Original"'])
        finally:
            srv.stop()


def jev(t, work):
    key_file = t.typesafe_key_file(work)
    fixture = t.triage_fixture()
    # A control with the same disposable subject proves that answered is the veto.
    for mark in (False, True):
        srv = t.Server(work, fixture=fixture)
        ts = t.TypeSafe(work)
        try:
            c, reply = t.tool(srv, "mail_reply", arguments(t, uid=t.SAFE, mark_answered=mark))
            t.check(f"reply marking Jev control mark={mark}: reply is accepted", c == 0, reply)
            c, result = t.triage_call(srv, ts, key_file, [t.SAFE], **t.BODY_MODE)
            message = next((m for m in result.get("messages", []) if m.get("uid") == t.SAFE), {})
            if mark:
                correct = (message.get("verdict") == "keep" and message.get("destination") is None
                           and "it has been answered" in message.get("vetoes", [])
                           and t.SAFE in t.msgs(srv.st(), "INBOX"))
            else:
                correct = (message.get("verdict") == "safe_to_delete" and message.get("destination") == t.REVIEW
                           and "it has been answered" not in message.get("vetoes", [])
                           and t.SAFE not in t.msgs(srv.st(), "INBOX"))
            t.check(f"reply marking Jev control mark={mark}: Answered supplies the existing veto",
                    c == 0 and correct, message)
        finally:
            ts.stop()
            srv.stop()
    fixture = copy.deepcopy(t.FIX)
    fixture["mailboxes"]["INBOX"]["messages"][0]["raw"] = (
        "From: alice@example.com\r\nSubject: [veto] Synthetic\r\n"
        "Message-ID: <veto@example.test>\r\n\r\nHello\r\n")
    srv = t.Server(work, fixture=fixture)
    ts = t.TypeSafe(work)
    try:
        c, result = t.tool(srv, "mail_reply", arguments(t), **t.jev_env(ts, key_file))
        t.check("reply marking: outbound Jev refusal cannot mark the original",
                c != 0 and result.get("jev", {}).get("decision") == "blocked"
                and no_status(result) and not stores(srv) and not srv.st()["sent"], result)
    finally:
        ts.stop()
        srv.stop()


def helper_evidence(t, work):
    for case, expected, reason, store_count in [
        ("not_started", False, "helper_not_started", 0),
        ("killed", "unverified", "mark_unverified", 0),
        ("wrong_uid", "unverified", "original_not_observed", 1),
        ("literal", "unverified", "original_not_observed", 1),
    ]:
        helper = Path(work) / "reply-evidence-helper"
        helper.write_text("#!/usr/bin/env python3\n" + f'''
import os, signal, subprocess, sys
from pathlib import Path
payload = sys.stdin.buffer.read()
mode = sys.argv[1]
mark = mode == "imap" and b"UID STORE" in payload
case = {case!r}
if mark and case == "killed":
    os.kill(os.getpid(), signal.SIGKILL)
p = subprocess.run([{str(t.ROOT / 'bin/mailbend-tls')!r}, mode], input=payload, capture_output=True)
out = p.stdout
if mark and case == "wrong_uid":
    out = out.replace(b"UID 1 FLAGS", b"UID 99 FLAGS")
if mark and case == "literal":
    fake = b"* 1 FETCH (UID 1 FLAGS (\\\\Answered))\\r\\na3 OK fake\\r\\na4 OK fake\\r\\n"
    replacement = b"* 1 FETCH (UID 1 BODY[] {{" + str(len(fake)).encode() + b"}}\\r\\n" + fake + b")\\r\\n"
    out = b"".join(replacement if b"UID 1 FLAGS" in line else line for line in out.splitlines(keepends=True))
if mode == "smtp" and case == "not_started":
    Path(__file__).unlink()
sys.stdout.buffer.write(out)
sys.stderr.buffer.write(p.stderr)
sys.exit(p.returncode)
''', encoding="utf-8")
        helper.chmod(0o700)
        srv = t.Server(work)
        try:
            c, result = t.tool(srv, "mail_reply", arguments(t), MAILBEND_TLS_HELPER=str(helper))
            t.check(f"reply marking helper {case}: only reliable mark evidence is reported",
                    c == 0 and result.get("smtp_outcome") == "accepted"
                    and result.get("original_marked") == expected
                    and result.get("original_mark_reason") == reason
                    and len(srv.st()["sent"]) == 1 and len(stores(srv)) == store_count, result)
        finally:
            srv.stop()


def run(t, work):
    exclusions(t, work)
    smtp_outcomes(t, work)
    followup_outcomes(t, work)
    sent_copy(t, work)
    identity(t, work)
    jev(t, work)
    helper_evidence(t, work)
