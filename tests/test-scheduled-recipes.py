#!/usr/bin/env python3
"""Exercise the one-shot examples against local fake mail, without timers or models."""
import copy
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples/scheduled"
spec = importlib.util.spec_from_file_location("recipe_fixtures", ROOT / "tests/test-e2e.py")
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)


def check(condition, message):
    assert condition, message
    print("PASS " + message)


def run(env, mode="notify"):
    script = "draft-follow-ups.sh" if mode == "drafts" else "poll.sh"
    args = [] if mode == "drafts" else [mode]
    result = subprocess.run(["bash", str(EXAMPLES / script), *args], env=env,
                            capture_output=True, text=True, timeout=30)
    assert t.PASSWORD not in result.stdout + result.stderr, "password leaked"
    return result


def checkpoint(env, uid, validity=t.INBOX_VALIDITY):
    path = Path(env["MAILBEND_RECIPE_STATE"]) / "checkpoint.json"
    path.write_text(json.dumps({"folder": "INBOX", "uidvalidity": validity, "since_uid": uid}))
    path.chmod(0o600)
    return path


def environment(srv, work, label):
    return {
        "PATH": str(work / "bin") + os.pathsep + os.environ["PATH"],
        "HOME": str(work), "LANG": "C.UTF-8", "BEND_NO_TELEMETRY": "1",
        "MAILBEND_BIN": t.LAUNCHER, "MAILBEND_EMAIL": t.FIX["user"],
        "MAILBEND_PASSWORD_FILE": str(work / "password"),
        "MAILBEND_IMAP_HOST": "localhost", "MAILBEND_IMAP_PORT": srv.imap,
        "MAILBEND_SMTP_HOST": "localhost", "MAILBEND_SMTP_PORT": srv.smtp,
        "MAILBEND_CA_FILE": str(work / "certs/ca.pem"), "MAILBEND_TIMEOUT_MS": "5000",
        "MAILBEND_RECIPE_STATE": str(work / label), "NOTIFY_LOG": str(work / "notifications"),
        "MAILBEND_TYPESAFE": "1", "MAILBEND_READ_ONLY": "0",
    }


def polling(srv, work):
    env = environment(srv, work, "notify")
    before = copy.deepcopy(srv.st()["mailboxes"])
    result = run(env)
    path = Path(env["MAILBEND_RECIPE_STATE"]) / "checkpoint.json"
    check(result.returncode == 0 and json.loads(path.read_text())["since_uid"] == 55,
          "first run seeds newest UID without replaying old messages")
    check(not (work / "notifications").exists(), "seed emits no desktop notification")
    check(run(env).returncode == 0 and not (work / "notifications").exists(),
          "empty arrival batch emits no notification")
    checkpoint(env, 0)
    check(run(env).returncode == 0 and json.loads(path.read_text())["since_uid"] == 50,
          "one tick processes the oldest 50 arrivals")
    check(run(env).returncode == 0 and json.loads(path.read_text())["since_uid"] == 55,
          "next tick processes the remaining arrivals")
    notices = [json.loads(line) for line in (work / "notifications").read_text().splitlines()]
    check(notices == [["--", "MailBend", "50 new messages in the next batch"],
                      ["--", "MailBend", "5 new messages in the next batch"]],
          "notifications contain only counts, never mail headers")
    checkpoint(env, 54)
    previous = path.read_bytes()
    check(run({**env, "NOTIFY_FAIL": "1"}).returncode != 0 and path.read_bytes() == previous,
          "notification failure preserves checkpoint")
    check(run(env).returncode == 0 and json.loads(path.read_text())["since_uid"] == 55,
          "retry of a read reaches the same checkpoint")
    with (path.parent / "lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        commands = len(srv.log_lines())
        check(run(env).returncode == 0 and len(srv.log_lines()) == commands,
              "overlapping invocation makes no mail call")
    previous = path.read_bytes()
    commands = len(srv.log_lines())
    check(run({**env, "MAILBEND_EMAIL": "other@example.com"}).returncode != 0 and
          path.read_bytes() == previous and len(srv.log_lines()) == commands,
          "different account refuses before connecting")
    check(run(env, "brief").returncode != 0 and path.read_bytes() == previous,
          "different recipe cannot consume another recipe's checkpoint")
    checkpoint(env, 54, 42)
    previous = path.read_bytes()
    check(run(env).returncode != 0 and path.read_bytes() == previous,
          "changed UIDVALIDITY stops without reseeding or advancing")
    checkpoint(env, 54)
    previous = path.read_bytes()
    password = work / "password"
    password.chmod(0o640)
    check(run(env).returncode != 0 and path.read_bytes() == previous,
          "group-readable password file is refused")
    password.chmod(0o600)
    check(run({**env, "MAILBEND_APP_PASSWORD": "synthetic-not-used"}).returncode != 0,
          "environment password is refused")
    path.write_text("not json")
    commands = len(srv.log_lines())
    check(run(env).returncode != 0 and path.read_text() == "not json" and
          len(srv.log_lines()) == commands, "corrupt checkpoint is not discarded")
    brief = {**env, "MAILBEND_RECIPE_STATE": str(work / "brief")}
    check(run(brief, "brief").returncode == 0, "brief seeds its separate checkpoint")
    checkpoint(brief, 54)
    check(run(brief, "brief").returncode == 0, "brief writes a batch")
    report = work / "brief" / f"{t.INBOX_VALIDITY}-54-55.txt"
    contents = report.read_bytes()
    check(b"UID 55 |" in contents and b"More batches waiting: false" in contents,
          "brief identifies messages and remaining work")
    checkpoint(brief, 54)
    check(run(brief, "brief").returncode == 0 and report.read_bytes() == contents,
          "replayed brief replaces the same batch without appending duplicates")
    check(b"unknown_people" in contents or b"people" in contents,
          "brief renders mail_brief primary groups, not the old bare summary")
    checkpoint(brief, 54, 42)
    brief_path = Path(brief["MAILBEND_RECIPE_STATE"]) / "checkpoint.json"
    previous = brief_path.read_bytes()
    check(run(brief, "brief").returncode != 0 and brief_path.read_bytes() == previous,
          "brief identity failure preserves the exact checkpoint")
    stub = work / "bin" / "incomplete-read"
    stub.write_text("#!/bin/sh\nprintf '%s\\n' '" + json.dumps(dict(
        folder="INBOX", uidvalidity=t.INBOX_VALIDITY, next_since_uid=54,
        has_more=False, messages=[])) + "'\n")
    stub.chmod(0o700)
    for selected_env, mode in ((env, "notify"), (brief, "brief")):
        target = checkpoint(selected_env, 54)
        previous = target.read_bytes()
        check(run({**selected_env, "MAILBEND_BIN": str(stub)}, mode).returncode != 0
              and target.read_bytes() == previous,
              mode + " refuses a result missing its required completion/identity marker")
    check(srv.st()["mailboxes"] == before and not srv.st().get("sent"),
          "polling leaves all mailbox state and flags unchanged")
    check(not any(any(verb in line for verb in t.MUTATING_COMMANDS + (" SELECT ",))
                  for line in srv.log_lines()), "polling uses no mutating IMAP command")
    check(not any(record.get("proto") == "smtp" for record in srv.log_records()),
          "polling never connects to SMTP")


def drafts(srv, work, uncertain=False, uidplus=True):
    label = "uncertain" if uncertain else ("drafts" if uidplus else "no-uidplus")
    env = environment(srv, work, label)
    queue = work / (label + "-queue")
    queue.mkdir(mode=0o700)
    env["MAILBEND_RECIPE_QUEUE"] = str(queue)
    job = queue / "follow-up-001.json"
    job.write_text(json.dumps({"folder": "INBOX", "uidvalidity": t.INBOX_VALIDITY,
                               "uid": 1, "body": "Synthetic follow-up for review."}))
    job.chmod(0o600)
    bad = queue / "aaa-invalid.json"
    bad.write_text(json.dumps({**json.loads(job.read_text()), "as_draft": False}))
    bad.chmod(0o600)
    commands = len(srv.log_lines())
    check(run(env, "drafts").returncode != 0 and len(srv.log_lines()) == commands,
          "job cannot override the draft-only command")
    bad.rename(work / (label + "-invalid-job.json"))
    original = copy.deepcopy(srv.st()["mailboxes"]["INBOX"])
    count = len(srv.st()["mailboxes"]["Drafts"]["messages"])
    result = run(env, "drafts")
    check((result.returncode != 0) == uncertain and
          len(srv.st()["mailboxes"]["Drafts"]["messages"]) == count + 1,
          "uncertain APPEND can save a draft" if uncertain else "queued job saves exactly one draft")
    claim = Path(env["MAILBEND_RECIPE_STATE"]) / "claims" / job.name
    check((claim / "request.json").is_file() and (claim / "done").exists() != uncertain,
          "claim records the request and distinguishes confirmed results")
    request = json.loads((claim / "request.json").read_text())
    check(request["as_draft"] is True and request["reply_all"] is False,
          "fixed reply command always drafts and never replies to all")
    if not uidplus:
        check(json.loads((claim / "result.json").read_text())["uid"] is None,
              "confirmed APPEND without APPENDUID completes with a null UID")
    commands = len(srv.log_lines())
    again = run(env, "drafts")
    check((again.returncode != 0) == uncertain and len(srv.log_lines()) == commands,
          "a claimed job is never sent to MailBend again")
    if uncertain:
        earlier = queue / "aaa.json"
        earlier.write_bytes(job.read_bytes())
        earlier.chmod(0o600)
        job.rename(work / "archived-job.json")
        check(run(env, "drafts").returncode != 0 and len(srv.log_lines()) == commands,
              "unfinished claim blocks earlier jobs even if its queue file is archived")
        earlier.rename(work / "archived-earlier-job.json")
        (claim / "reviewed").touch(mode=0o600)
        check(run(env, "drafts").returncode == 0 and len(srv.log_lines()) == commands,
              "explicit human reconciliation unblocks the queue without replaying a claim")
    check(srv.st()["mailboxes"]["INBOX"] == original and not srv.st().get("sent"),
          "drafts do not send or change the source message")
    check(not any(record.get("proto") == "smtp" for record in srv.log_records()),
          "draft recipe never connects to SMTP")


def main():
    for service in EXAMPLES.glob("*.service"):
        text = service.read_text()
        check("Type=oneshot\n" in text and "TimeoutStartSec=120\n" in text and
              "Restart=" not in text and "Environment=MAILBEND_PASSWORD_FILE=" in text and
              ("Environment=MAILBEND_READ_ONLY=1\n" in text or
               "Environment=MAILBEND_DRAFTS_ONLY=1\n" in text),
              service.name + " bounds runs and sets server-side safety and password-file settings")
    with tempfile.TemporaryDirectory(prefix="mailbend-recipes-", dir="/tmp") as directory:
        work = Path(directory)
        subprocess.run(["sh", str(ROOT / "tests/gen-test-certs.sh"), str(work / "certs")],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        password = work / "password"
        password.write_text(t.PASSWORD)
        password.chmod(0o600)
        (work / "bin").mkdir()
        notifier = work / "bin/notify-send"
        notifier.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                            "if os.environ.get('NOTIFY_FAIL'): sys.exit(1)\n"
                            "with open(os.environ['NOTIFY_LOG'], 'a') as f:\n"
                            "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n")
        notifier.chmod(0o700)
        fixture = copy.deepcopy(t.FIX)
        template = fixture["mailboxes"]["INBOX"]["messages"][0]
        fixture["mailboxes"]["INBOX"]["messages"] = [
            {**template, "uid": uid, "raw": template["raw"].replace(
                "<hello@example.com>", f"<recipe-{uid}@example.com>")}
            for uid in range(1, 56)]
        srv = t.Server(str(work), fixture=fixture)
        try:
            polling(srv, work)
            drafts(srv, work)
        finally:
            srv.stop()
        srv = t.Server(str(work), caps="MOVE,SPECIAL-USE,IDLE")
        try:
            drafts(srv, work, uidplus=False)
        finally:
            srv.stop()
        srv = t.Server(str(work), extra=("--drop-unanswered", "APPEND"))
        try:
            drafts(srv, work, uncertain=True)
        finally:
            srv.stop()
    print("Scheduled recipes passed without models, real mail, or installed timers.")


if __name__ == "__main__":
    main()
