#!/usr/bin/env python3
"""Negative controls for the soak's verdict, without launching mail or Bend."""
import ast
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
import queue

spec = importlib.util.spec_from_file_location("soak", Path(__file__).with_name("test-soak.py"))
soak = importlib.util.module_from_spec(spec)
spec.loader.exec_module(soak)


class SoakContract(unittest.TestCase):
    def test_metrics_and_drift(self):
        samples = [(0, 100000), (1, 100000), (2, 120000), (3, 130000)]
        self.assertEqual(soak.check_metrics([.1] * 500, samples, 1)["p95_drift_ratio"], 1)
        for bad_samples in ([(0, 100000), (2, soak.RSS_LIMIT_KIB + 1)],
                            [(0, 100000), (2, 100000 + soak.RSS_GROWTH_KIB + 1)],
                            [(2, 100000)], [(0, 100000)]):
            with self.assertRaises(AssertionError):
                soak.check_metrics([.1] * 500, bad_samples, 1)
        with self.assertRaises(AssertionError):
            soak.check_metrics([.1] * 450 + [.31] * 50, samples, 1)

    def test_reply_ids_and_actual_work(self):
        sent = soak.request(10, 4)
        good = {"jsonrpc": "2.0", "id": 10, "result": {
            "structuredContent": {"changed": [1], "flagged": True}}}
        soak.check_reply(good, sent)
        for bad in (dict(good, id=9), dict(good, id=11), dict(good, id=True),
                    dict(good, result={"isError": True}),
                    dict(good, result={"structuredContent": {"changed": [], "flagged": True}})):
            with self.assertRaises(AssertionError):
                soak.check_reply(bad, sent)

    def test_expected_failures_are_not_successes(self):
        sent = soak.request(7, 6)
        soak.check_reply({"jsonrpc": "2.0", "id": 7, "error": {"code": -32601}}, sent)
        with self.assertRaises(AssertionError):
            soak.check_reply({"jsonrpc": "2.0", "id": 7, "result": {}}, sent)
        invalid = soak.request(8, 7)
        soak.check_reply({"jsonrpc": "2.0", "id": 8, "result": {"isError": True}}, invalid)
        with self.assertRaises(AssertionError):
            soak.check_reply({"jsonrpc": "2.0", "id": 8, "result": {}}, invalid)

    def test_gap_summary_reports_checked_work_only(self):
        self.assertEqual(soak.gap_summary({}), {})
        result = soak.gap_summary({"mail_get": [.1, .3], "tools/list": [.01], "unused": []})
        self.assertEqual(result["mail_get"]["checked_replies"], 2)
        self.assertAlmostEqual(result["mail_get"]["total_seconds"], .4)
        self.assertEqual(result["mail_get"]["max_seconds"], .3)
        self.assertNotIn("unused", result)

    def test_reply_deadline_and_stall(self):
        replies = Mock()
        replies.get.return_value = (1, {"id": 1})
        with patch.object(soak.time, "monotonic", return_value=100):
            self.assertEqual(soak.next_reply(replies, 110), (1, {"id": 1}))
            replies.get.assert_called_once_with(timeout=10)
        replies.get.side_effect = queue.Empty
        for clock, deadline, reason in (([100, 130], 200, "no MCP reply within 30 seconds"),
                                        ([100, 110], 110, "soak time budget exceeded"),
                                        ([110], 110, "soak time budget exceeded")):
            with patch.object(soak.time, "monotonic", side_effect=clock):
                with self.assertRaisesRegex(AssertionError, reason):
                    soak.next_reply(replies, deadline)

    def test_phase_wait_success_timeout_and_reader_failure(self):
        for timeout, failure in ((30, "no initialize reply within 30 seconds"),
                                 (10, "core did not close stdout after EOF")):
            for reply in ((1, {"id": 0, "result": {}}), (2, None),
                          (3, {"reader_failed": True})):
                replies = Mock()
                replies.get.return_value = reply
                self.assertIs(soak.phase_reply(replies, timeout, failure), reply)
                replies.get.assert_called_once_with(timeout=timeout)
            replies = Mock()
            replies.get.side_effect = queue.Empty
            with self.assertRaisesRegex(AssertionError, "^" + failure + "$"):
                soak.phase_reply(replies, timeout, failure)
            replies.get.assert_called_once_with(timeout=timeout)
            replies.get.side_effect = OSError("reader error")
            with self.assertRaisesRegex(OSError, "reader error"):
                soak.phase_reply(replies, timeout, failure)

    def test_phase_waits_use_diagnostic_wrapper(self):
        # Pin the real run() boundary: testing the wrapper alone cannot detect
        # a call-site regression back to a bare Queue.get().
        def check(tree):
            for function in tree.body:
                if not isinstance(function, ast.FunctionDef):
                    continue
                raw_gets = [node for node in ast.walk(function)
                            if isinstance(node, ast.Call)
                            and isinstance(node.func, ast.Attribute)
                            and isinstance(node.func.value, ast.Name)
                            and node.func.value.id == "replies" and node.func.attr == "get"]
                if function.name not in ("phase_reply", "next_reply"):
                    self.assertEqual(raw_gets, [], "reply wait bypasses timeout diagnostics")
            run = next(node for node in tree.body
                       if isinstance(node, ast.FunctionDef) and node.name == "run")
            waits = sorted((node for node in ast.walk(run)
                            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                            and node.func.id == "phase_reply"), key=lambda node: node.lineno)
            self.assertEqual(len(waits), 2)
            for call, timeout in zip(waits, (30, 10)):
                self.assertEqual(ast.dump(call.args[0]), ast.dump(ast.Name(id="replies", ctx=ast.Load())))
                self.assertEqual(ast.literal_eval(call.args[1]), timeout)

            return waits

        original = ast.parse(Path(soak.__file__).read_text())
        reformatted = copy.deepcopy(original)
        for call in check(reformatted):
            call.args[2] = ast.Constant(value="Reworded phase diagnostic")
        # Formatting and message changes are irrelevant to this wiring guard.
        reformatted = ast.parse(ast.unparse(reformatted).replace(
            "phase_reply(replies,", "phase_reply(\n                    replies,"))
        # Both actual call sites must be wrapped, not just the helper definition.
        # Otherwise a no-op replacement would silently drop this positive control.
        for call in check(reformatted):
            self.assertGreater(call.args[0].lineno, call.lineno,
                               "positive fixture no longer wraps phase_reply arguments")
        for tree in (original, reformatted):
            check(tree)
            for index in (0, 1):
                mutant = copy.deepcopy(tree)
                call = check(mutant)[index]
                queue_arg, timeout = call.args[:2]
                call.func = ast.Attribute(value=queue_arg, attr="get", ctx=ast.Load())
                call.args = []
                call.keywords = [ast.keyword(arg="timeout", value=timeout)]
                with self.assertRaisesRegex(AssertionError, "bypasses timeout diagnostics"):
                    check(mutant)

    def test_cleanup_does_not_signal_reaped_leader(self):
        proc = Mock(pid=1234, returncode=0)
        with patch.object(soak.os, "killpg") as kill:
            soak.stop(proc)
            kill.assert_not_called()
            proc.wait.assert_not_called()
            proc.returncode = None
            soak.stop(proc)
            kill.assert_called_once_with(1234, soak.signal.SIGKILL)
            proc.wait.assert_called_once_with(timeout=10)

    def test_comparison_windows_have_identical_mix(self):
        expected = [
            {"jsonrpc": "2.0", "method": "tools/list", "params": {}},
            {"jsonrpc": "2.0", "method": "tools/call",
             "params": {"name": "mail_probe", "arguments": {}}},
            {"jsonrpc": "2.0", "method": "tools/call",
             "params": {"name": "mail_search", "arguments": {"limit": 2}}},
            {"jsonrpc": "2.0", "method": "tools/call",
             "params": {"name": "mail_get", "arguments": {"uid": 1}}},
            {"jsonrpc": "2.0", "method": "tools/call",
             "params": {"name": "mail_flag", "arguments": {"uids": [1], "uidvalidity": 1700000001}}},
            {"jsonrpc": "2.0", "method": "tools/call",
             "params": {"name": "mail_unflag", "arguments": {"uids": [1], "uidvalidity": 1700000001}}},
            {"jsonrpc": "2.0", "method": "soak/unknown", "params": {}},
            {"jsonrpc": "2.0", "method": "tools/call",
             "params": {"name": "mail_get", "arguments": {"uid": 0}}},
            {"jsonrpc": "2.0", "method": "tools/call",
             "params": {"name": "mail_search", "arguments": {"limit": 2}}},
            {"jsonrpc": "2.0", "method": "tools/call",
             "params": {"name": "mail_get", "arguments": {"uid": 1}}},
        ]
        for count in (500, 5000):
            for start in (50, 50 + count - count // 10):
                for index in range(start, start + count // 10):
                    with self.subTest(count=count, index=index):
                        payload = {key: value for key, value in soak.request(index + 1, index).items()
                                   if key != "id"}
                        self.assertEqual(json.dumps(payload, sort_keys=True),
                                         json.dumps(expected[index % 10], sort_keys=True),
                                         "comparison-window payload")


if __name__ == "__main__":
    unittest.main()
