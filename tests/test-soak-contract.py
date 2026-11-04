#!/usr/bin/env python3
"""Negative controls for the soak's verdict, without launching mail or Bend."""
import importlib.util
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
        for count in (500, 5000):
            first = [soak.request(i, i)["method"] for i in range(count // 10)]
            last = [soak.request(i, i)["method"] for i in range(count - count // 10, count)]
            self.assertEqual(first, last)


if __name__ == "__main__":
    unittest.main()
