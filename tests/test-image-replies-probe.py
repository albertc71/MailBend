#!/usr/bin/env python3
"""Keep the optional image comparison probe buildable without benchmarking."""
import importlib.util
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "image_replies", Path(__file__).with_name("compare-image-replies.py"))
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class ImageRepliesProbe(unittest.TestCase):
    def test_replacement_rejects_missing_and_duplicate_anchors(self):
        for source in ("absent", "marker marker"):
            with self.subTest(source=source), self.assertRaises(ValueError):
                probe.replace_once(source, "marker", "replacement")
        self.assertEqual(probe.replace_once("a marker b", "marker", "new"), "a new b")

    def test_generator_rejects_template_anchor_drift(self):
        original = probe.TEMPLATE.read_text()
        anchor = "T.part_bytes(run, uid, 42,"
        self.assertEqual(original.count(anchor), 1)
        with tempfile.TemporaryDirectory(prefix="image-probe-drift-") as directory:
            work = Path(directory)
            template = work / "template.bend"
            for count in (0, 2):
                with self.subTest(anchor_count=count):
                    template.write_text(original.replace(anchor, anchor * count))
                    with mock.patch.object(probe, "TEMPLATE", template):
                        with self.assertRaisesRegex(ValueError, re.escape(repr(anchor))):
                            probe.probe_source(probe.ROOT, True, work)

    def test_generated_variants_compile_and_count_tiny_replies(self):
        # Exercise the same generator and all prepared-path replacement anchors
        # as the comparison tool. No reference checkout, timing or scale run.
        build = probe.ROOT / "build"
        build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="image-probe-smoke-", dir=build) as directory:
            work = Path(directory)
            for prepared in (False, True):
                with self.subTest(prepared=prepared):
                    source = work / "probe.bend"
                    binary = work / "probe"
                    source.write_text(probe.probe_source(probe.ROOT, prepared, work))
                    text = source.read_text()
                    self.assertEqual("T.part_prepared(" in text, prepared)
                    self.assertEqual("T.part_bytes(" in text, not prepared)
                    probe.command(["bend", str(source), "-o", str(binary)], timeout=300)
                    for shape in ("small", "complex"):
                        with self.subTest(shape=shape):
                            output = probe.command([str(binary), "7", "2", shape], timeout=30)
                            self.assertEqual(output, "56")  # Four slots, seven bytes, two rounds.


if __name__ == "__main__":
    unittest.main()
