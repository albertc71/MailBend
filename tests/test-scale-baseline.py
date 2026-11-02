#!/usr/bin/env python3
"""Fast source-consistency gate for selected scale records, not candidate capture."""
import hashlib
import json
import pathlib
import unittest

from scale_baseline import BASELINES, select_baseline

ROOT = pathlib.Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class BaselineSource(unittest.TestCase):
    def test_every_selected_baseline_matches_current_source(self):
        self.assertTrue(BASELINES, "no selected baseline")
        dependencies = {name: digest(ROOT / "tests" / name) for name in
                        ("image_fixtures.py", "fake_mail_server.py", "fake_typesafe.py")}
        for cpu in BASELINES:
            with self.subTest(cpu=cpu):
                profile = json.loads(select_baseline(cpu).read_text())["profile"]
                self.assertEqual(profile["cpu"], cpu)
                self.assertEqual(profile["fixture_dependencies_sha256"], dependencies)
                self.assertEqual(profile["fixture_generator_sha256"],
                                 digest(ROOT / "tests/scale_fixtures.py"))
                self.assertEqual(profile["measurement_sha256"],
                                 digest(ROOT / "tests/test-scale.py"))


if __name__ == "__main__":
    unittest.main()
