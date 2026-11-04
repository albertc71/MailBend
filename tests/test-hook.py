#!/usr/bin/env python3
"""Exercise the offline hook through the same launcher configured in Claude Code."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unicodedata
import unittest

ROOT = Path(__file__).resolve().parent.parent
COMMAND = [str(ROOT / "scripts/mailbend"), "hook", "claude-pretooluse"]
CAP = 65536


def event(name="mail_send", **args):
    return {"hook_event_name": "PreToolUse", "tool_name": f"mcp__mailbend__{name}",
            "tool_input": args}


def encoded(value):
    return json.dumps(value, ensure_ascii=False).encode()


class Hook(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mailbend-hook-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.called = self.root / "helper-called"
        helper = self.root / "forbidden-helper"
        helper.write_text(f"#!/bin/sh\nprintf called >> '{self.called}'\nexit 97\n")
        helper.chmod(0o700)
        self.env = {key: val for key, val in os.environ.items()
                    if not key.startswith("MAILBEND_") and key not in
                    {"SSL_CERT_FILE", "SSL_CERT_DIR"}}
        self.env.update(BEND_NO_TELEMETRY="1", MAILBEND_READ_ONLY="bad-value",
                        MAILBEND_TYPESAFE="bad-value",
                        MAILBEND_TYPESAFE_KEY_FILE=str(self.root / "absent-key"))
        for suffix in ("TLS", "ATTACH", "TYPESAFE"):
            self.env[f"MAILBEND_{suffix}_HELPER"] = str(helper)

    def run_hook(self, raw=None, **kwargs):
        result = subprocess.run(COMMAND, input=raw, capture_output=True, env=self.env,
                                timeout=30, **kwargs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        self.assertFalse(self.called.exists(), "hook started a mail helper")
        return result.stdout

    def ask(self, raw=None, **kwargs):
        output = json.loads(self.run_hook(raw, **kwargs))
        self.assertEqual(set(output), {"hookSpecificOutput"})
        decision = output["hookSpecificOutput"]
        self.assertEqual(set(decision), {"hookEventName", "permissionDecision",
                                         "permissionDecisionReason"})
        self.assertEqual(decision["hookEventName"], "PreToolUse")
        self.assertEqual(decision["permissionDecision"], "ask")
        reason = decision["permissionDecisionReason"]
        self.assertLessEqual(len(reason), 1024)
        self.assertFalse(any(unicodedata.category(char) in {"Cc", "Cf"} for char in reason))
        return reason

    def test_change_truth_table(self):
        for name in ("mail_send", "mail_reply", "mail_forward", "mail_delete"):
            for dry in (False, "true", 1, None, True):
                with self.subTest(tool=name, dry=dry):
                    raw = encoded(event(name, dry_run=dry))
                    if dry is True:
                        self.assertEqual(self.run_hook(raw), b"")
                    else:
                        self.ask(raw)

    def test_drafts_and_other_known_operations_are_silent(self):
        for name in ("mail_reply", "mail_forward"):
            self.assertEqual(self.run_hook(encoded(event(name, as_draft=True))), b"")
            self.ask(encoded(event(name, as_draft="true")))
        for name in ("mail_save_draft", "mail_trash", "mail_get", "mail_search", "mail_probe"):
            self.assertEqual(self.run_hook(encoded(event(name))), b"")
        self.ask(encoded(event("mail_send", as_draft=True)))

    def test_malformed_or_unknown_events_ask(self):
        for raw in (b"", b"{", b"[]", b"null", b"{}", b"{} {}", b"{}\xff",
                    b"\xef\xbb\xbf{}", b"\xc0\xaf", b"\xed\xa0\x80", b"\xf0\x90"):
            with self.subTest(raw=raw):
                self.ask(raw)
        for value in ({"hook_event_name": "PostToolUse", "tool_name": "mail_get",
                       "tool_input": {}},
                      {"hook_event_name": "PreToolUse", "tool_name": "mail_get"},
                      {"hook_event_name": "PreToolUse", "tool_name": 7, "tool_input": {}},
                      {"hook_event_name": "PreToolUse", "tool_name": "mail_get", "tool_input": []},
                      event("unknown", dry_run=True)):
            self.ask(encoded(value))

    def test_last_separator_and_bare_names(self):
        for name in ("mail_reply", "mcp__mailbend__mail_reply", "mcp__custom___mail_reply"):
            value = event("mail_reply", as_draft=True)
            value["tool_name"] = name
            self.assertEqual(self.run_hook(encoded(value)), b"")

    def test_reason_has_only_bounded_selected_facts(self):
        value = event(to=["to@example.test"], cc=["cc@example.test"],
                      bcc=["bcc@example.test"], subject="A\u202e\u2066 subject\n\x00",
                      attachments=[{"path": "/private/one"}, {"path": "/private/two"}],
                      reply_all=True, body="UNSHARED_BODY", unrelated="UNSHARED_FIELD")
        reason = self.ask(encoded(value))
        for expected in ("mail_send", "to@example.test", "cc@example.test",
                         "bcc@example.test", "subject=", "attachments=2", "reply_all=true"):
            self.assertIn(expected, reason)
        for hidden in ("UNSHARED_BODY", "UNSHARED_FIELD", "/private/one", "/private/two"):
            self.assertNotIn(hidden, reason)
        self.ask(encoded(event(subject="\u202e" * 500 + "😀" * 5000)))
        reply = self.ask(encoded(event("mail_reply", reply_all=True)))
        self.assertIn("Recipients come from the original message", reply)
        self.assertIn("dry_run", reply)

    def test_recipient_counts_and_truncated_fields_are_visible(self):
        args = {key: [f"{key}{index:03}@example.test" for index in range(count)]
                for key, count in (("to", 48), ("cc", 23), ("bcc", 12))}
        args["subject"] = "界" * 300
        reason = self.ask(encoded(event("mail_reply", **args)))
        for key in ("to", "cc", "bcc"):
            self.assertIn(f"{key}_count={len(args[key])}; {key}=", reason)
            self.assertNotIn(args[key][-1], reason)
        for key in ("to", "cc", "bcc", "subject"):
            field = reason.split(f"{key}=", 1)[1].split(";", 1)[0]
            self.assertEqual(len(field), 160)
            self.assertTrue(field.endswith(" [truncated]"), field)
        self.assertIn("Recipients come from the original message", reason)
        self.assertIn("attachments=0", reason)
        self.assertIn("reply_all=false", reason)

    def test_field_truncation_boundary_and_recipient_count_shapes(self):
        for char in ("x", "界", "😀"):
            for length in (157, 158, 159):
                with self.subTest(char=char, length=length):
                    reason = self.ask(encoded(event(subject=char * length)))
                    field = reason.split("subject=", 1)[1].split(";", 1)[0]
                    if length <= 158:
                        self.assertEqual(field, json.dumps(char * length, ensure_ascii=False))
                        self.assertNotIn("[truncated]", reason)
                    else:
                        self.assertEqual(len(field), 160)
                        self.assertTrue(field.endswith(" [truncated]"))
        reason = self.ask(encoded(event(to=[], cc=["one@example.test"], bcc="invalid")))
        self.assertIn("to_count=0; to=[]", reason)
        self.assertIn('cc_count=1; cc=["one@example.test"]', reason)
        self.assertIn('bcc_count=(invalid); bcc="invalid"', reason)
        missing = self.ask(encoded(event()))
        for key in ("to", "cc", "bcc"):
            self.assertIn(f"{key}_count=0; {key}=(not supplied)", missing)

    def test_file_multiline_and_byte_cap(self):
        raw = json.dumps(event("mail_get"), indent=2).encode()
        for size in (CAP - 1, CAP):
            padded = raw + b" " * (size - len(raw))
            self.assertEqual(self.run_hook(padded), b"")
        self.ask(raw + b" " * (CAP + 1 - len(raw)))
        path = self.root / "event.json"
        path.write_bytes(raw)
        with path.open("rb") as source:
            self.assertEqual(self.run_hook(stdin=source), b"")

    def test_utf8_split_across_chunks(self):
        prefix = b'{"ignored":"'
        for char in ("é", "界", "😀"):
            raw = (prefix + b"x" * (4095 - len(prefix)) + char.encode() +
                   b'","hook_event_name":"PreToolUse","tool_name":"mail_get","tool_input":{}}')
            self.assertEqual(self.run_hook(raw), b"")

    def test_waits_for_eof_and_rejects_trailing_document(self):
        proc = subprocess.Popen(COMMAND, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=self.env)
        try:
            proc.stdin.write(encoded(event("mail_get")))
            proc.stdin.flush()
            time.sleep(0.15)
            self.assertIsNone(proc.poll(), "hook decided before EOF")
            proc.stdin.write(b" {}")
            proc.stdin.close()
            proc.stdin = None
            out, err = proc.communicate(timeout=30)
            self.assertEqual(proc.returncode, 0, err)
            self.assertEqual(json.loads(out)["hookSpecificOutput"]["permissionDecision"], "ask")
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait()

    def test_unreadable_stdin_asks(self):
        left, right = socket.socketpair()
        with left, right:
            self.ask(stdin=left)
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            self.ask(stdin=fd)
        finally:
            os.close(fd)
        self.ask(preexec_fn=lambda: os.close(0))


if __name__ == "__main__":
    unittest.main()
