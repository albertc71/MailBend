"""Literal malformed-transport diagnostics, independent of the product parser."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from harness_output import cli_value, mcp_tool, transport_failure


class OutputControls(unittest.TestCase):
    def test_valid_application_refusal_remains_a_value(self):
        self.assertEqual(cli_value('{"error":"refused"}\n', 1, "", ()), {"error": "refused"})

    def test_empty_and_malformed_cli_are_harness_failures(self):
        for output in ("", "not-json", "[]"):
            with self.subTest(output=output):
                with self.assertRaisesRegex(RuntimeError, '"exit_code": 17') as caught:
                    cli_value(output, 17, "synthetic-startup-failure", ())
                self.assertIn("synthetic-startup-failure", str(caught.exception))
                self.assertTrue("not-json" not in str(caught.exception), "raw stdout was displayed")

    def test_missing_malformed_or_wrong_identity_mcp_never_indexes(self):
        good = {"jsonrpc": "2.0", "id": 1, "result": {
            "isError": False, "content": [{"type": "text", "text": '{"ok":true}'}],
            "structuredContent": {"ok": True}}}
        self.assertEqual(mcp_tool([good], 0, "", ()), good["result"])
        refused = {**good, "result": {**good["result"], "isError": True,
                                     "structuredContent": {"error": "refused"},
                                     "content": [{"type": "text", "text": '{"error":"refused"}'}]}}
        self.assertEqual(mcp_tool([refused], 1, "", ()), refused["result"])
        for replies in ([], [None], [{"id": 0, "result": {}}],
                        [{**good, "id": 2}], [{**good, "result": {"isError": False}}]):
            with self.subTest(replies=replies):
                with self.assertRaisesRegex(RuntimeError, "mcp tool reply"):
                    mcp_tool(replies, 0, "marker", ())
        with self.assertRaises(RuntimeError) as caught:
            mcp_tool([{**good, "id": 2}], 0, "", (), stdout='{"id":2}\n')
        self.assertEqual(json.loads(str(caught.exception))["stdout_bytes"], 9)

    def test_redaction_precedes_excerpt_cut_and_omits_stdout(self):
        secret = "private-synthetic-password"
        plain = "\0reader@example.test\0" + secret
        stderr = "x" * 2038 + secret + " " + base64.b64encode(plain.encode()).decode() + " marker"
        with self.assertRaises(RuntimeError) as caught:
            transport_failure("cli", 9, "raw-mail-must-not-appear", stderr, (secret, plain))
        result = json.loads(str(caught.exception))
        self.assertEqual(result["exit_code"], 9)
        self.assertTrue(result["stderr_truncated"])
        self.assertLessEqual(len(result["stderr"]), 2048)
        self.assertTrue(result["stderr"].endswith("<redacted>"))
        self.assertTrue("private-sy" not in result["stderr"], "fixture prefix was displayed")
        self.assertTrue(secret not in str(caught.exception), "fixture secret was displayed")
        self.assertTrue(base64.b64encode(plain.encode()).decode() not in str(caught.exception), "encoded fixture secret was displayed")
        self.assertTrue("raw-mail-must-not-appear" not in str(caught.exception), "raw stdout was displayed")

    def test_visible_auth_encoding_and_plaintext_are_both_redacted(self):
        secret = "private-synthetic-password"
        plain = "\0reader@example.test\0" + secret
        stderr = secret + " " + base64.b64encode(plain.encode()).decode() + " marker"
        with self.assertRaises(RuntimeError) as caught:
            transport_failure("cli", 17, "", stderr, (secret, plain))
        self.assertTrue(json.loads(str(caught.exception))["stderr"] == "<redacted> <redacted> marker", "fixture redaction differs")


class TransportIntegrationControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("diagnostic_e2e", Path(__file__).with_name("test-e2e.py"))
        cls.e2e = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.e2e
        spec.loader.exec_module(cls.e2e)

    def test_empty_cli_fails_at_both_public_read_boundaries(self):
        import nested_reads
        server = SimpleNamespace(env=lambda **kwargs: {})
        child = subprocess.CompletedProcess([], 17, "", "synthetic-startup-failure")
        with patch.dict(os.environ, {"MAILBEND_TEST_MCP": "0"}):
            for call in (lambda: self.e2e.tool(server, "mail_get"),
                         lambda: nested_reads.wire(self.e2e, server, {})):
                with patch.object(subprocess, "run", return_value=child):
                    with self.assertRaisesRegex(RuntimeError, '"exit_code": 17'):
                        call()

    def test_empty_mcp_fails_before_tool_indexing(self):
        import nested_reads
        server = SimpleNamespace(env=lambda **kwargs: {})
        child = SimpleNamespace(returncode=17, communicate=lambda *args, **kwargs:
                                (b"", b"synthetic-startup-failure"))
        with patch.dict(os.environ, {"MAILBEND_TEST_MCP": "1"}):
            for call in (lambda: self.e2e.tool(server, "mail_get"),
                         lambda: nested_reads.wire(self.e2e, server, {})):
                with patch.object(subprocess, "Popen", return_value=child):
                    with self.assertRaisesRegex(RuntimeError, "mcp initialization"):
                        call()

    def test_effective_server_credentials_are_redacted(self):
        import nested_reads
        environment = {"MAILBEND_EMAIL": "alternate@example.test", "MAILBEND_APP_PASSWORD": "alternate-secret"}
        server = SimpleNamespace(env=lambda **kwargs: dict(environment))
        stderr = "alternate-secret alternate@example.test marker"
        for mode in ("0", "1"):
            with patch.dict(os.environ, {"MAILBEND_TEST_MCP": mode}):
                for call in (lambda: self.e2e.tool(server, "mail_get"),
                             lambda: nested_reads.wire(self.e2e, server, {})):
                    child = (subprocess.CompletedProcess([], 17, "", stderr) if mode == "0" else
                             SimpleNamespace(returncode=17, communicate=lambda *args, **kwargs: (b"", stderr.encode())))
                    with patch.object(subprocess, "run" if mode == "0" else "Popen", return_value=child):
                        with self.assertRaises(RuntimeError) as caught:
                            call()
                        self.assertTrue(json.loads(str(caught.exception))["stderr"] == "<redacted> <redacted> marker", "effective fixture redaction differs")

    def test_legacy_wire_returns_original_success_bytes(self):
        import nested_reads
        server = SimpleNamespace(env=lambda **kwargs: {})
        original = ' { "error" : "literal\\nbytes" } \n'
        with patch.dict(os.environ, {"MAILBEND_TEST_MCP": "0"}):
            with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, original, "")):
                self.assertEqual(nested_reads.wire(self.e2e, server, {}), (0, original.rstrip("\n")))


if __name__ == "__main__":
    unittest.main()
