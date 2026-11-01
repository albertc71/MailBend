#!/usr/bin/env python3
"""Fast controls for scale measurement, comparison and synthetic input shape."""
import importlib.util
import pathlib
import sys
import tempfile
import time
import unittest

from scale_fixtures import SCENARIOS, Scenario, fixture, sized_message

SPEC = importlib.util.spec_from_file_location("scale", pathlib.Path(__file__).with_name("test-scale.py"))
scale = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scale)


def sample(count=1):
    return {"status": "passed", "wall_seconds": 1.0, "peak_rss_kib": 1000,
            "imap_logins": 2, "exit_code": 0, "timed_out": False,
            "work": {"fixture_count": count, "body_bytes_fetched": 0,
                     "smtp_messages": 0, "typesafe_requests": 0}}


def report():
    return {"status": "measured", "profile": {"runner": "synthetic-test"},
            "scenarios": {s.name: scale.summarize([sample(s.count) for _ in range(5)]) for s in SCENARIOS}}


class Contract(unittest.TestCase):
    def test_equal_baseline(self):
        self.assertEqual(scale.compare(report(), report()), [])

    def test_deliberate_slowdown(self):
        old, new = report(), report()
        row = new["scenarios"][SCENARIOS[0].name]
        for s in row["samples"]:
            s["wall_seconds"] *= 1.26
        new["scenarios"][SCENARIOS[0].name] = scale.summarize(row["samples"])
        self.assertEqual(scale.compare(old, new), ["search-100000: wall_seconds exceeds baseline by more than 25%"])

    def test_exact_threshold(self):
        old, new = report(), report()
        for s in new["scenarios"][SCENARIOS[0].name]["samples"]:
            s["wall_seconds"] *= 1.25
        new["scenarios"][SCENARIOS[0].name] = scale.summarize(new["scenarios"][SCENARIOS[0].name]["samples"])
        self.assertEqual(scale.compare(old, new), [])

    def test_other_resource_regressions(self):
        for key in ("peak_rss_kib", "imap_logins"):
            old, new = report(), report()
            for s in new["scenarios"][SCENARIOS[0].name]["samples"]:
                s[key] *= 2
            new["scenarios"][SCENARIOS[0].name] = scale.summarize(new["scenarios"][SCENARIOS[0].name]["samples"])
            self.assertTrue(scale.compare(old, new), key)

    def test_incomplete_never_passes(self):
        for status in ("unmeasured", "incomplete", "failed"):
            bad = report()
            bad["status"] = status
            self.assertTrue(scale.compare(bad, report()))
            self.assertTrue(scale.compare(report(), bad))

    def test_profile_mismatch(self):
        new = report()
        new["profile"]["runner"] = "another-host"
        self.assertIn("not comparable", scale.compare(report(), new)[0])

    def test_missing_scenario(self):
        new = report()
        del new["scenarios"][SCENARIOS[0].name]
        self.assertEqual(scale.compare(report(), new), ["scenario coverage differs"])

    def test_forged_summary(self):
        new = report()
        new["scenarios"][SCENARIOS[0].name]["metrics"]["wall_seconds"]["median"] = 0.1
        self.assertTrue(scale.compare(report(), new))

    def test_invalid_off_median_sample(self):
        for value in (float("nan"), float("inf"), -1, 0, True, "1", None):
            new = report()
            new["scenarios"][SCENARIOS[0].name]["samples"][0]["wall_seconds"] = value
            self.assertTrue(scale.compare(report(), new), str(value))

    def test_failure_is_not_speed(self):
        for key, value in (("status", "failed"), ("exit_code", 1), ("timed_out", True)):
            samples = [sample() for _ in range(5)]
            samples[0][key] = value
            self.assertEqual(scale.summarize(samples)["status"], "incomplete")
        self.assertEqual(scale.summarize([sample()])["status"], "incomplete")

    def test_wrong_work_is_not_speed(self):
        new = report()
        for s in new["scenarios"][SCENARIOS[0].name]["samples"]:
            s["work"]["fixture_count"] = 10
        self.assertTrue(scale.compare(report(), new))

    def test_malformed_shapes_refused(self):
        for value in (None, [], "bad", 1):
            self.assertTrue(scale.compare(value, report()))
            bad = report()
            bad["scenarios"] = value
            self.assertTrue(scale.compare(report(), bad))
            bad = report()
            bad["scenarios"][SCENARIOS[0].name] = value
            self.assertTrue(scale.compare(report(), bad))

    def test_exact_bytes(self):
        for size in (1024, 4096, 8192):
            raw = sized_message(size)["raw"]
            self.assertEqual(len(raw.encode("ascii")), size)
            self.assertTrue(raw.endswith("SCALE-END\r\n"))
            self.assertLessEqual(max(map(len, raw.split("\r\n"))), 998)

    def test_fixed_scale_sizes(self):
        self.assertEqual([s.count for s in SCENARIOS], [100000, 1000, 5000, 16 * 1024 ** 2,
                                                       25 * 1024 ** 2, 1000, 50])

    def test_thread_topology(self):
        data = fixture(Scenario("test", "mail_get_thread", {"uid": 1}, 10, "thread"))
        raws = [m["raw"] for m in data["mailboxes"]["INBOX"]["messages"]]
        ids = [raw.split("Message-ID: ")[1].split("\r\n")[0] for raw in raws]
        self.assertEqual(len(set(ids)), 10)
        self.assertTrue(all(f"References: {ids[0]}\r\n" in raw for raw in raws[1:]))

    def test_clean_environment(self):
        env = scale.clean_env(pathlib.Path("/tmp/synthetic"))
        self.assertEqual(set(env), {"PATH", "HOME", "LANG", "LC_ALL", "BEND_NO_TELEMETRY"})

    def test_rss_is_per_child(self):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            env = scale.clean_env(work)
            high = scale.measure([sys.executable, "-c", "x=bytearray(64*1024*1024); print(len(x))"], env, work, 5)
            low = scale.measure([sys.executable, "-c", "print('small')"], env, work, 5)
            self.assertEqual((high["exit_code"], low["exit_code"]), (0, 0))
            self.assertGreater(high["peak_rss_kib"], low["peak_rss_kib"] + 32000)

    def test_fixture_parent_is_not_measured(self):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            dirty = bytearray(96 * 1024 * 1024)
            dirty[::4096] = b"x" * (len(dirty) // 4096)
            result = scale.measure([sys.executable, "-c", "print('small')"],
                                   scale.clean_env(work), work, 5)
            self.assertEqual(result["exit_code"], 0)
            self.assertLess(result["peak_rss_kib"], 48000)

    def test_timeout_is_a_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            result = scale.measure([sys.executable, "-c", "import time; time.sleep(5)"],
                                   scale.clean_env(work), work, 0.05)
            self.assertTrue(result["timed_out"])
            self.assertNotEqual(result["exit_code"], 0)

    def test_partial_readiness_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            start = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, "startup timed out"):
                scale.Server([sys.executable, "-c", "import sys,time;sys.stdout.write('READY');sys.stdout.flush();time.sleep(5)"],
                             scale.clean_env(work), work, "partial", 0.05)
            self.assertLess(time.monotonic() - start, 2)


if __name__ == "__main__":
    unittest.main()
