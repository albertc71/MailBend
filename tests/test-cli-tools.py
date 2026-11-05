#!/usr/bin/env python3
"""Discover tool names and schemas through the public, credential-free CLI."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
LAUNCHER = ROOT / "scripts/mailbend"
READ_TOOLS = [
    "mail_probe", "mail_list_folders", "mail_search", "mail_get", "mail_get_new",
    "mail_brief", "mail_refresh", "mail_get_thread", "mail_awaiting_reply",
    "mail_contacts", "mail_correspondents",
]
WRITE_TOOLS = [
    "mail_get_attachment", "mail_mark_read", "mail_mark_unread", "mail_flag",
    "mail_unflag", "mail_move", "mail_label", "mail_trash", "mail_delete",
    "mail_create_folder", "mail_rename_folder", "mail_save_draft", "mail_send",
    "mail_reply", "mail_forward",
]


class ToolDiscovery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mailbend-discovery-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.called = self.root / "helper-called"
        helper = self.root / "forbidden-helper"
        helper.write_text(f"#!/bin/sh\nprintf called >> '{self.called}'\nexit 97\n")
        helper.chmod(0o700)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("MAILBEND_")
                    and key not in {"SSL_CERT_FILE", "SSL_CERT_DIR"}}
        for suffix in ("TLS", "ATTACH", "TYPESAFE"):
            self.env[f"MAILBEND_{suffix}_HELPER"] = str(helper)

    def run_tools(self, *args, **env):
        result = subprocess.run([str(LAUNCHER), "tools", *args], input=b"",
                                capture_output=True, env={**self.env, **env}, timeout=120)
        self.assertFalse(self.called.exists(), "discovery started a mail helper")
        return result

    def discover(self, *args, **env):
        result = self.run_tools(*args, **env)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stderr, b"")
        return json.loads(result.stdout)

    def configurations(self):
        jev = {"MAILBEND_TYPESAFE": "1",
               "MAILBEND_TYPESAFE_KEY_FILE": str(self.root / "absent-key")}
        drafts = [name for name in WRITE_TOOLS if name != "mail_send"]
        return [
            ({}, READ_TOOLS + WRITE_TOOLS),
            ({"MAILBEND_READ_ONLY": "TRUE"}, READ_TOOLS),
            ({"MAILBEND_DRAFTS_ONLY": "1"}, READ_TOOLS + drafts),
            ({"MAILBEND_READ_ONLY": "1", "MAILBEND_DRAFTS_ONLY": "1"}, READ_TOOLS),
            (jev, READ_TOOLS + ["mail_classify", "mail_triage"] + WRITE_TOOLS),
            ({**jev, "MAILBEND_READ_ONLY": "1"}, READ_TOOLS + ["mail_classify"]),
            ({**jev, "MAILBEND_DRAFTS_ONLY": "1"},
             READ_TOOLS + ["mail_classify", "mail_triage"] + drafts),
        ]

    def test_read_only_names_are_an_ordered_json_string_array(self):
        self.assertEqual(self.discover("--names", MAILBEND_READ_ONLY="1"), READ_TOOLS)

    def test_helper_sentinel_detects_a_real_tool_dispatch(self):
        result = subprocess.run([str(LAUNCHER), "call", "mail_probe", "{}"],
                                input=b"", capture_output=True, env=self.env, timeout=120)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.called.read_text(), "called")

    def test_names_match_configuration_and_bare_order(self):
        for env, expected in self.configurations():
            with self.subTest(env=env):
                names = self.discover("--names", **env)
                self.assertEqual(names, expected)
                self.assertEqual(names, [tool["name"] for tool in self.discover(**env)])

    def test_named_schemas_match_available_bare_entries(self):
        for env, expected in self.configurations():
            listed = self.discover(**env)
            self.assertEqual([tool["name"] for tool in listed], expected)
            for tool in listed:
                with self.subTest(env=env, name=tool["name"]):
                    selected = self.discover(tool["name"], **env)
                    self.assertEqual(selected, tool)
                    self.assertNotIn("outputSchema", selected)

    def test_named_hidden_tools_are_unavailable_in_each_configuration(self):
        known = READ_TOOLS + ["mail_classify", "mail_triage"] + WRITE_TOOLS
        for env, expected in self.configurations():
            for name in known:
                if name not in expected:
                    with self.subTest(env=env, name=name):
                        result = self.run_tools(name, **env)
                        self.assertEqual(result.returncode, 2)
                        self.assertEqual(result.stdout, b"")
                        self.assertEqual(result.stderr, b"mailbend: unknown or unavailable tool\n")

    def test_invalid_safety_and_typesafe_settings_offer_only_reads(self):
        jev = {"MAILBEND_TYPESAFE": "1",
               "MAILBEND_TYPESAFE_KEY_FILE": str(self.root / "absent-key")}
        invalid = [
            {"MAILBEND_READ_ONLY": "yes"}, {"MAILBEND_DRAFTS_ONLY": "on"},
            {"MAILBEND_TYPESAFE": "yes"}, {"MAILBEND_TYPESAFE_CONTENT": "everything"},
            {"MAILBEND_TYPESAFE_ZERO_RETENTION": "yes"}, {"MAILBEND_TYPESAFE_IMAGES": "yes"},
            {"MAILBEND_TYPESAFE_API_KEY": ""}, {"MAILBEND_TYPESAFE_KEY_FILE": "relative"},
            {"MAILBEND_TYPESAFE_CONTENT": "body"}, {"MAILBEND_TYPESAFE_IMAGES": "1"},
        ]
        for settings in invalid:
            env = {**jev, **settings}
            with self.subTest(settings=settings):
                self.assertEqual(self.discover("--names", **env), READ_TOOLS)
                listed = self.discover(**env)
                self.assertEqual([tool["name"] for tool in listed], READ_TOOLS)
                self.assertEqual(self.discover("mail_get", **env), listed[3])
                for name in ("mail_send", "mail_classify"):
                    result = self.run_tools(name, **env)
                    self.assertEqual(result.returncode, 2)
                    self.assertEqual(result.stdout, b"")
                    self.assertEqual(result.stderr, b"mailbend: unknown or unavailable tool\n")

    def test_unknown_names_have_a_fixed_diagnostic_without_echoing_input(self):
        for name in ("unknown_tool", "", "--unknown", "mail_get\x1b[31m\nprivate"):
            with self.subTest(name=name):
                result = self.run_tools(name)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"mailbend: unknown or unavailable tool\n")

    def test_extra_arguments_are_usage_errors(self):
        for args in (("--names", "mail_get"), ("mail_get", "{}"),
                     ("--names", "--names"), ("mail_get", "mail_send")):
            with self.subTest(args=args):
                result = self.run_tools(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, b"")
                self.assertTrue(result.stderr.startswith(b"usage: mailbend "))
                self.assertIn(b"mailbend tools [--names | <tool>]", result.stderr)

    def test_discovery_does_not_wait_for_credential_fifo_writers(self):
        password = self.root / "password-fifo"
        key = self.root / "key-fifo"
        os.mkfifo(password, 0o600)
        os.mkfifo(key, 0o600)
        env = {"MAILBEND_PASSWORD_FILE": str(password), "MAILBEND_TYPESAFE": "1",
               "MAILBEND_TYPESAFE_KEY_FILE": str(key)}
        expected = READ_TOOLS + ["mail_classify", "mail_triage"] + WRITE_TOOLS
        self.assertEqual(self.discover("--names", **env), expected)
        self.assertEqual(self.discover("mail_classify", **env)["name"], "mail_classify")
        self.assertEqual([tool["name"] for tool in self.discover(**env)], expected)

    def test_invalid_send_only_settings_do_not_change_discovery(self):
        env = {"MAILBEND_SECRET_SCAN": "invalid", "MAILBEND_MAX_SENDS_PER_DAY": "invalid"}
        expected = READ_TOOLS + WRITE_TOOLS
        self.assertEqual(self.discover("--names", **env), expected)
        self.assertEqual([tool["name"] for tool in self.discover(**env)], expected)
        self.assertEqual(self.discover("mail_send", **env)["name"], "mail_send")

    def test_named_read_tool_returns_its_legacy_schema_object(self):
        tool = self.discover("mail_get", MAILBEND_READ_ONLY="1")
        self.assertEqual(tool["name"], "mail_get")
        self.assertEqual(tool["title"], "Read a message")
        self.assertEqual(tool["inputSchema"]["required"], ["uid"])
        self.assertEqual(tool["inputSchema"]["properties"]["uid"]["type"], "integer")
        self.assertIs(tool["annotations"]["readOnlyHint"], True)
        self.assertNotIn("outputSchema", tool)

    def test_named_write_tool_is_hidden_in_read_only_mode(self):
        result = self.run_tools("mail_send", MAILBEND_READ_ONLY="1")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"mailbend: unknown or unavailable tool\n")

    def test_named_write_tool_keeps_dry_run_and_interaction_metadata(self):
        tool = self.discover("mail_send")
        self.assertEqual(tool["name"], "mail_send")
        self.assertEqual(tool["title"], "Send mail")
        self.assertIs(tool["annotations"]["readOnlyHint"], False)
        self.assertEqual(tool["inputSchema"]["type"], "object")
        self.assertIs(tool["inputSchema"]["additionalProperties"], False)
        self.assertEqual(tool["inputSchema"]["properties"]["dry_run"]["type"], "boolean")
        self.assertEqual(tool["_meta"], {"anthropic/requiresUserInteraction": True})
        self.assertIs(tool["_meta"]["anthropic/requiresUserInteraction"], True)
        self.assertNotIn("outputSchema", tool)


if __name__ == "__main__":
    unittest.main()
