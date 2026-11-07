#!/usr/bin/env python3
"""Guard plugin declarations and exercise a Python-only launch emulation.

--runtime also runs the real hook and MCP launcher against the loopback mail
fixture. Python performs substitutions, environment merges and argv launches
in both modes; they do not test Claude's handling of any of these operations.
Neither mode runs Claude or proves that Claude loads the plugin.
"""
import argparse
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read_json(path):
    return json.loads((ROOT / path).read_text())


def resolve_command(entry, config):
    """Emulate substitutions in Python, without testing Claude's implementation."""
    def expand(value):
        return re.sub(r"\$\{user_config\.([a-z_]+)\}",
                      lambda match: config[match[1]], value)
    return ([expand(entry["command"]), *map(expand, entry.get("args", []))],
            {key: expand(value) for key, value in entry.get("env", {}).items()})


class Packaging(unittest.TestCase):
    def test_marketplace_discovers_the_existing_skill(self):
        plugin = read_json(".claude-plugin/plugin.json")
        marketplace = read_json(".claude-plugin/marketplace.json")
        self.assertEqual(plugin["name"], "mailbend")
        self.assertEqual(plugin["version"], "0.1.1")
        self.assertEqual(marketplace["name"], "mailbend")
        self.assertTrue(marketplace["description"].strip())
        self.assertEqual(marketplace["plugins"], [{"name": "mailbend", "source": "./"}])
        self.assertTrue((ROOT / "skills/mailbend/SKILL.md").is_file())
        self.assertNotIn("skills", plugin, "use the standard skills directory, without a copy")
        self.assertNotIn("hooks", plugin, "hooks/hooks.json is auto-discovered")
        self.assertNotIn("commands", plugin)
        self.assertNotIn("agents", plugin)


class PythonLaunchEmulation(unittest.TestCase):
    """Finite manifest guards plus a local harness, not evidence of client behavior."""
    def setUp(self):
        self.plugin = read_json(".claude-plugin/plugin.json")
        self.temp = tempfile.TemporaryDirectory(prefix="mailbend-plugin-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        install = self.work / "installed '\";$(touch INJECTED); & $HOME"
        (install / "scripts").mkdir(parents=True)
        launcher = install / "scripts/mailbend"
        launcher.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "print(json.dumps({'args': sys.argv[1:], 'input': sys.stdin.read(),\n"
            "                  'env': {k: v for k, v in os.environ.items()\n"
            "                          if k.startswith('MAILBEND_')}}))\n")
        launcher.chmod(0o700)
        self.password = self.work / "password '\";$(touch PASSWORD_INJECTED);.txt"
        self.password.write_text("synthetic-file-content-not-a-user-setting\n")
        self.password.chmod(0o600)
        self.config = {"mailbend_dir": str(install), "email": "reader@example.test",
                       "password_file": str(self.password)}
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("MAILBEND_")}

    def launch(self, entry, raw=""):
        command, overrides = resolve_command(entry, self.config)
        result = subprocess.run(command, env=self.env | overrides, input=raw,
                                capture_output=True, text=True, cwd=self.work, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertNotIn("synthetic-file-content-not-a-user-setting", result.stdout)
        self.assertNotIn("synthetic-inherited-password", result.stdout + result.stderr)
        self.assertFalse((self.work / "INJECTED").exists())
        self.assertFalse((self.work / "PASSWORD_INJECTED").exists())
        return json.loads(result.stdout)

    def test_manifest_defaults_and_paths_in_python_launch_emulation(self):
        """Guard declarations; substitution/merge/argv assertions cover only this harness."""
        fields = self.plugin["userConfig"]
        self.assertEqual(set(fields), {"mailbend_dir", "email", "password_file",
                                       "read_only", "drafts_only"})
        for key, kind in (("mailbend_dir", "directory"), ("email", "string"),
                          ("password_file", "file")):
            self.assertEqual(fields[key]["type"], kind)
            self.assertIs(fields[key]["required"], True)
            self.assertNotIn("default", fields[key])
        for key in ("read_only", "drafts_only"):
            self.assertEqual(fields[key]["type"], "string")
            self.assertEqual(fields[key]["options"], ["1", "0"])
            self.assertEqual(fields[key]["default"], "1")
            self.config[key] = fields[key]["default"]
        self.assertFalse(any(field.get("sensitive") for field in fields.values()))
        self.assertEqual(set(self.plugin["mcpServers"]), {"mailbend"})
        server_env = self.plugin["mcpServers"]["mailbend"]["env"]
        self.assertEqual(server_env["MAILBEND_APP_PASSWORD"], "")
        self.assertNotIn("MAILBEND_TYPESAFE_API_KEY", server_env,
                         "the core refuses this variable even when empty")
        self.env.update(MAILBEND_LOGIN="wrong-inherited-login", MAILBEND_READ_ONLY="0",
                        MAILBEND_APP_PASSWORD="synthetic-inherited-password",
                        MAILBEND_DRAFTS_ONLY="0", MAILBEND_TYPESAFE="1",
                        MAILBEND_IMAP_HOST="imap.example.test", MAILBEND_IMAP_PORT="1993")
        result = self.launch(self.plugin["mcpServers"]["mailbend"])
        self.assertEqual(result, {
            "args": ["mcp"], "input": "",
            "env": {"MAILBEND_EMAIL": "reader@example.test", "MAILBEND_LOGIN": "",
                    "MAILBEND_APP_PASSWORD": "",
                    "MAILBEND_PASSWORD_FILE": str(self.password),
                    "MAILBEND_READ_ONLY": "1", "MAILBEND_DRAFTS_ONLY": "1",
                    "MAILBEND_TYPESAFE": "0", "MAILBEND_IMAP_HOST": "imap.example.test",
                    "MAILBEND_IMAP_PORT": "1993"}})

    def test_write_mode_substitutions_in_python_launch_emulation(self):
        for read_only, drafts_only in (("1", "0"), ("0", "1"), ("0", "0")):
            with self.subTest(read_only=read_only, drafts_only=drafts_only):
                self.config.update(read_only=read_only, drafts_only=drafts_only)
                result = self.launch(self.plugin["mcpServers"]["mailbend"])
                self.assertEqual(result["env"]["MAILBEND_READ_ONLY"], read_only)
                self.assertEqual(result["env"]["MAILBEND_DRAFTS_ONLY"], drafts_only)

    def test_plugin_hook_uses_exec_arguments_and_requests_failure_blocking(self):
        hooks = read_json("hooks/hooks.json")["hooks"]
        self.assertEqual(set(hooks), {"PreToolUse"})
        self.assertEqual(len(hooks["PreToolUse"]), 1)
        group = hooks["PreToolUse"][0]
        self.assertEqual(set(group), {"matcher", "hooks"})
        for name in ("mcp__plugin_mailbend_mailbend__mail_send",
                     "mcp__plugin_mailbend_mailbend__future_tool"):
            self.assertIsNotNone(re.fullmatch(group["matcher"], name))
        for name in ("mcp__mailbend__mail_send", "mcp__plugin_other_mailbend__mail_send",
                     "mcp__plugin_mailbend_mailbend_other__mail_send",
                     "prefix_mcp__plugin_mailbend_mailbend__mail_send", "Bash"):
            self.assertIsNone(re.search(group["matcher"], name))
        self.assertEqual(len(group["hooks"]), 1)
        hook = group["hooks"][0]
        self.assertEqual(set(hook), {"type", "command", "args", "onFailure", "timeout"})
        self.assertEqual(hook["type"], "command")
        self.assertEqual(hook["onFailure"], "block")
        self.assertEqual(hook["timeout"], 30)
        self.assertNotIn("shell", hook)
        raw = '{"hook_event_name":"PreToolUse","tool_name":"mcp__plugin_mailbend_mailbend__mail_send","tool_input":{}}'
        result = self.launch(hook, raw)
        self.assertEqual(result, {"args": ["hook", "claude-pretooluse"], "input": raw, "env": {}})


class Runtime(unittest.TestCase):
    """Real MailBend launcher/hook with Python-resolved config, not a Claude session."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mailbend-plugin-runtime-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.plugin = read_json(".claude-plugin/plugin.json")
        self.config = {key: field["default"] for key, field in self.plugin["userConfig"].items()
                       if "default" in field}
        self.config.update(mailbend_dir=str(ROOT), email="tester@example.com",
                           password_file=str(self.work / "password"))
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("MAILBEND_") and key not in
                    {"SSL_CERT_FILE", "SSL_CERT_DIR"}}

    def test_plugin_scoped_hook_asks_or_stays_silent_without_helpers(self):
        entry = read_json("hooks/hooks.json")["hooks"]["PreToolUse"][0]["hooks"][0]
        command, overrides = resolve_command(entry, self.config)
        helper = self.work / "forbidden-helper"
        helper.write_text("#!/bin/sh\nprintf called > \"$MARKER\"\nexit 97\n")
        helper.chmod(0o700)
        marker = self.work / "helper-called"
        self.env["MARKER"] = str(marker)
        for name in ("TLS", "ATTACH", "TYPESAFE"):
            self.env[f"MAILBEND_{name}_HELPER"] = str(helper)
        for name, args, asks in (("mail_send", {}, True), ("mail_delete", {}, True),
                                  ("mail_reply", {}, True), ("mail_forward", {}, True),
                                  ("future_tool", {"dry_run": True}, True),
                                  ("mail_send", {"dry_run": True}, False),
                                  ("mail_delete", {"dry_run": True}, False),
                                  ("mail_reply", {"as_draft": True}, False),
                                  ("mail_forward", {"as_draft": True}, False),
                                  ("mail_get", {}, False)):
            with self.subTest(tool=name, args=args):
                event = {"hook_event_name": "PreToolUse",
                         "tool_name": f"mcp__plugin_mailbend_mailbend__{name}", "tool_input": args}
                result = subprocess.run(command, input=json.dumps(event), capture_output=True,
                                        text=True, env=self.env | overrides, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertFalse(marker.exists(), "hook started a mail helper")
                if asks:
                    output = json.loads(result.stdout)
                    self.assertEqual(set(output), {"hookSpecificOutput"})
                    decision = output["hookSpecificOutput"]
                    self.assertEqual(set(decision), {"hookEventName", "permissionDecision",
                                                     "permissionDecisionReason"})
                    self.assertEqual(decision["hookEventName"], "PreToolUse")
                    self.assertEqual(decision["permissionDecision"], "ask")
                else:
                    self.assertEqual(result.stdout, "")

    def test_python_resolved_mcp_probe_and_read_only_refusals(self):
        for name in ("mailbend-core", "mailbend-stdio", "mailbend-tls"):
            self.assertTrue(os.access(ROOT / "bin" / name, os.X_OK),
                            "--runtime requires this checkout's binaries; run scripts/install.sh")
        subprocess.run(["sh", str(ROOT / "tests/gen-test-certs.sh"), str(self.work / "certs"),
                        "--demo"], check=True, capture_output=True, env=self.env, timeout=30)
        fixture = read_json("tests/fixtures/mailbox.json")
        password = Path(self.config["password_file"])
        password.write_text(fixture["password"] + "\n")
        password.chmod(0o600)
        state, log = self.work / "state.json", self.work / "log.jsonl"
        server = subprocess.Popen([
            sys.executable, str(ROOT / "tests/fake_mail_server.py"),
            "--certdir", str(self.work / "certs"), "--fixture", str(ROOT / "tests/fixtures/mailbox.json"),
            "--state", str(state), "--log", str(log)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        self.addCleanup(server.stdout.close)
        self.addCleanup(server.stderr.close)
        def stop_server():
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
        self.addCleanup(stop_server)
        self.assertTrue(select.select([server.stdout], [], [], 10)[0], "fake mail server did not start")
        ready = server.stdout.readline().decode().split()
        self.assertEqual(ready[0], "READY", ready)
        ports = dict(item.split("=") for item in ready[1:])
        self.env.update(MAILBEND_IMAP_HOST="localhost", MAILBEND_IMAP_PORT=ports["imap"],
                        MAILBEND_SMTP_HOST="localhost", MAILBEND_SMTP_PORT=ports["smtp"],
                        MAILBEND_CA_FILE=str(self.work / "certs/ca.pem"),
                        MAILBEND_TIMEOUT_MS="10000", MAILBEND_LOGIN="wrong-inherited-login",
                        MAILBEND_APP_PASSWORD="synthetic-inherited-password",
                        MAILBEND_READ_ONLY="0", MAILBEND_DRAFTS_ONLY="0", MAILBEND_TYPESAFE="1")
        before = json.loads(state.read_text())
        requests = [
            {"jsonrpc": "2.0", "id": 0, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "mail_probe", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": {"name": "mail_send", "arguments": {"to": ["recipient@example.test"],
                         "subject": "Synthetic plugin test", "body": "Must not send"}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
             "params": {"name": "mail_delete", "arguments": {"uids": [1], "uidvalidity": 1700000001,
                         "confirm": "permanently-delete"}}}]
        command, overrides = resolve_command(self.plugin["mcpServers"]["mailbend"], self.config)
        result = subprocess.run(command, input="".join(json.dumps(request) + "\n" for request in requests),
                                text=True, capture_output=True, env=self.env | overrides, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(fixture["password"], result.stdout + result.stderr)
        self.assertNotIn("synthetic-inherited-password", result.stdout + result.stderr)
        replies = [json.loads(line) for line in result.stdout.split("\n") if line]
        self.assertEqual([reply["id"] for reply in replies], [0, 1, 2, 3, 4])
        self.assertEqual(replies[0]["result"]["protocolVersion"], "2025-06-18")
        names = {tool["name"] for tool in replies[1]["result"]["tools"]}
        self.assertEqual(names, {"mail_probe", "mail_list_folders", "mail_search", "mail_get",
                                 "mail_get_new", "mail_brief", "mail_refresh", "mail_get_thread",
                                 "mail_awaiting_reply", "mail_contacts", "mail_correspondents"})
        probe = replies[2]["result"]
        self.assertFalse(probe["isError"])
        self.assertIs(probe["structuredContent"]["ok"], True)
        self.assertIs(probe["structuredContent"]["tls_verified"], True)
        for reply in replies[3:]:
            self.assertTrue(reply["result"]["isError"])
            self.assertIn("MAILBEND_READ_ONLY is set", reply["result"]["structuredContent"]["error"])
        self.assertEqual(json.loads(state.read_text()), before, "read-only session changed the mailbox")
        lines = [json.loads(line)["line"] for line in log.read_text().splitlines()]
        self.assertTrue(any(" LIST " in line for line in lines), "probe did not reach the fixture")
        for forbidden in (" SELECT ", " APPEND ", " STORE ", " EXPUNGE", " COPY ", " MOVE ",
                          " CREATE ", " RENAME ", " SUBSCRIBE ", " UNSUBSCRIBE ", "MAIL FROM:"):
            self.assertFalse(any(forbidden in line for line in lines), forbidden)

    def test_jev_off_still_refuses_inherited_invalid_or_inconsistent_settings_before_helpers(self):
        """The real core rejects these settings even with the manifest's Jev-off override."""
        helper = self.work / "forbidden-helper"
        helper.write_text("#!/bin/sh\nprintf called > \"$MARKER\"\nexit 97\n")
        helper.chmod(0o700)
        marker = self.work / "helper-called"
        self.env["MARKER"] = str(marker)
        for name in ("TLS", "ATTACH", "TYPESAFE"):
            self.env[f"MAILBEND_{name}_HELPER"] = str(helper)
        command, overrides = resolve_command(self.plugin["mcpServers"]["mailbend"], self.config)
        requests = [
            {"jsonrpc": "2.0", "id": 0, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "mail_probe", "arguments": {}}}]
        cases = (
            ({"MAILBEND_TYPESAFE_API_KEY": ""}, "MAILBEND_TYPESAFE_API_KEY must not be set"),
            ({"MAILBEND_TYPESAFE_CONTENT": "invalid"}, "MAILBEND_TYPESAFE_CONTENT must be"),
            ({"MAILBEND_TYPESAFE_ZERO_RETENTION": "invalid"},
             "MAILBEND_TYPESAFE_ZERO_RETENTION must be 1, true, 0, false or empty"),
            ({"MAILBEND_TYPESAFE_IMAGES": "invalid"},
             "MAILBEND_TYPESAFE_IMAGES must be 1, true, 0, false or empty"),
            ({"MAILBEND_TYPESAFE_CONTENT": "body"}, "MAILBEND_TYPESAFE_ZERO_RETENTION=1"),
            ({"MAILBEND_TYPESAFE_CONTENT": "body", "MAILBEND_TYPESAFE_ZERO_RETENTION": "0"},
             "MAILBEND_TYPESAFE_ZERO_RETENTION=1"),
            ({"MAILBEND_TYPESAFE_IMAGES": "1"},
             "MAILBEND_TYPESAFE_IMAGES needs MAILBEND_TYPESAFE_CONTENT=body"),
            ({"MAILBEND_TYPESAFE_IMAGES": "1", "MAILBEND_TYPESAFE_CONTENT": "headers",
              "MAILBEND_TYPESAFE_ZERO_RETENTION": "1"},
             "MAILBEND_TYPESAFE_IMAGES needs MAILBEND_TYPESAFE_CONTENT=body"),
        )
        for inherited, error in cases:
            with self.subTest(inherited=inherited):
                result = subprocess.run(command,
                                        input="".join(json.dumps(r) + "\n" for r in requests),
                                        capture_output=True, text=True,
                                        env=self.env | inherited | overrides, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                replies = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual([reply["id"] for reply in replies], [0, 1])
                reply = replies[1]
                self.assertTrue(reply["result"]["isError"])
                self.assertIn(error, reply["result"]["structuredContent"]["error"])
                self.assertFalse(marker.exists(), "invalid config started a mail helper")

    def test_jev_off_accepts_inherited_supported_settings_before_tls_helper(self):
        """Valid settings reach a synthetic TLS failure, without mail or TypeSafe access."""
        marker = self.work / "helper-called"
        self.env["MARKER"] = str(marker)
        for name in ("TLS", "ATTACH", "TYPESAFE"):
            helper = self.work / f"forbidden-{name.lower()}-helper"
            helper.write_text(
                f"#!/bin/sh\nprintf '%s\\n' {name} >> \"$MARKER\"\n"
                "printf '%s\\n' 'mailbend-tls: synthetic plugin probe boundary' >&2\n"
                "exit 97\n")
            helper.chmod(0o700)
            self.env[f"MAILBEND_{name}_HELPER"] = str(helper)
        command, overrides = resolve_command(self.plugin["mcpServers"]["mailbend"], self.config)
        requests = [
            {"jsonrpc": "2.0", "id": 0, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "mail_probe", "arguments": {}}}]
        cases = (
            {"MAILBEND_TYPESAFE_CONTENT": "body", "MAILBEND_TYPESAFE_ZERO_RETENTION": "1",
             "MAILBEND_TYPESAFE_IMAGES": "1"},
            {"MAILBEND_TYPESAFE_CONTENT": "headers", "MAILBEND_TYPESAFE_ZERO_RETENTION": "1"},
        )
        for inherited in cases:
            with self.subTest(inherited=inherited):
                marker.unlink(missing_ok=True)
                result = subprocess.run(command,
                                        input="".join(json.dumps(r) + "\n" for r in requests),
                                        capture_output=True, text=True,
                                        env=self.env | inherited | overrides, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                replies = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual([reply["id"] for reply in replies], [0, 1])
                reply = replies[1]["result"]
                self.assertTrue(reply["isError"])
                self.assertEqual(reply["structuredContent"]["error"],
                                 "mail server error: synthetic plugin probe boundary")
                self.assertTrue(marker.exists(), "supported config did not reach the TLS helper")
                self.assertEqual(marker.read_text().splitlines(), ["TLS"],
                                 "probe started an attachment or TypeSafe helper")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, add_help=False)
    parser.add_argument("--runtime", action="store_true")
    args, rest = parser.parse_known_args()
    cases = ["Packaging", "PythonLaunchEmulation"] + (["Runtime"] if args.runtime else [])
    unittest.main(argv=[sys.argv[0], *rest], defaultTest=cases)
