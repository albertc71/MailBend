#!/usr/bin/env python3
"""Reject guide edits that would silently skip a Bend example."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "writing_laws", ROOT / "tests/formal/check-writing-laws.py")
GUIDE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUIDE)


class SnippetTests(unittest.TestCase):
    def setUp(self):
        self.blocks = [f"```bend guide:{name}\ndef {proof}():\n  {{==}}\n```\n"
                       for name, proof in GUIDE.PATTERNS.items()]

    def parse(self, text):
        with tempfile.TemporaryDirectory(prefix="mailbend-guide-parser-") as directory:
            path = Path(directory) / "guide.md"
            path.write_text(text, encoding="utf-8")
            return GUIDE.snippets(path)

    def test_checked_in_guide(self):
        source = GUIDE.snippets(ROOT / "docs/WRITING-LAWS.md")
        self.assertTrue(source.startswith("import Base\n"))
        self.assertIn("def search_writes_nothing(mbox, keys):", source)

    def test_preserves_code_and_order(self):
        source = self.parse("\n".join(self.blocks))
        self.assertEqual(source.count("{==}"), len(GUIDE.PATTERNS))
        self.assertLess(source.index("def search_writes_nothing("),
                        source.index("def true_is_not_false("))

    def test_rejects_invalid_blocks(self):
        valid = "\n".join(self.blocks)
        cases = {
            "missing": "\n".join(self.blocks[:-1]),
            "duplicate": valid + self.blocks[0],
            "unknown": valid.replace("guide:computation", "guide:unknown"),
            "unclosed": valid.rstrip()[:-3],
            "unmarked": valid + "```bend\ndef skipped():\n  {==}\n```\n",
            "empty": valid.replace("def search_writes_nothing():\n  {==}", ""),
            "comment only": valid.replace("def search_writes_nothing():", "# no proof"),
            "reordered": "\n".join(reversed(self.blocks)),
            "indented": valid + "   ```bend\ninvalid\n   ```\n",
            "tilde": valid + "~~~bend\ninvalid\n~~~\n",
            "long fence": valid + "````bend\ninvalid\n````\n",
            "indented closer": valid.replace("\n```\n", "\n  ```\n", 1),
            "nested": valid.replace("def search_writes_nothing():", "```bend guide:computation"),
            "other code block": valid.replace("def search_writes_nothing():", "```sh"),
        }
        for name, text in cases.items():
            with self.subTest(name=name), self.assertRaises(AssertionError):
                self.parse(text)


class SourceMatchTests(unittest.TestCase):
    def setUp(self):
        self.source = GUIDE.snippets(ROOT / "docs/WRITING-LAWS.md")
        self.laws = (ROOT / "LAWS.bend").read_text(encoding="utf-8")
        self.proofs = (ROOT / "PROOF.bend").read_text(encoding="utf-8")

    def check(self, source=None, laws=None, proofs=None):
        GUIDE.require_source_match(self.source if source is None else source,
                                   self.laws if laws is None else laws,
                                   self.proofs if proofs is None else proofs)

    def test_current_declarations_match(self):
        self.check()
        self.check(source="\r\n".join(line + "  " for line in self.source.splitlines()))

    def test_rejects_source_drift(self):
        cases = [
            (self.laws.replace("law search_writes_nothing:", "law renamed_search:"), self.proofs),
            (self.laws.replace("for keys: List<&2, I.Key>", "for keys: List<&2, String>", 1), self.proofs),
            (self.laws, self.proofs.replace("def bool_motive(b: Bool)", "def bool_motive(b: U32)")),
            (self.laws, self.proofs.replace("def Laws.search_writes_nothing(mbox, keys):\n  {==}",
                                           "def Laws.search_writes_nothing(mbox, keys):\n  {==}\n  {==}")),
        ]
        for index, (laws, proofs) in enumerate(cases):
            reason = "missing source declaration" if index == 0 else "differs from source declaration"
            with self.subTest(case=index), self.assertRaisesRegex(AssertionError, reason):
                self.check(laws=laws, proofs=proofs)

    def test_rejects_guide_drift_and_unmatched_text(self):
        cases = [
            self.source.replace("def bool_motive(b: Bool)", "def bool_motive(b: U32)"),
            self.source + "\ndef bool_motive(b: Bool):\n  Unit\n",
            self.source + "\ndef untracked():\n  Unit{}\n",
            self.source + "\nopaque unchecked\n",
            self.source.replace("    case True{}:", "  case True{}:", 1),
        ]
        reasons = ["differs from source declaration", "duplicate def bool_motive",
                   "missing source declaration untracked", "unsupported top-level snippet text",
                   "differs from source declaration"]
        for source, reason in zip(cases, reasons):
            with self.subTest(reason=reason), self.assertRaisesRegex(AssertionError, reason):
                self.check(source=source)

    def test_does_not_normalize_string_contents(self):
        with self.assertRaisesRegex(AssertionError, "differs from source declaration text"):
            GUIDE.require_source_match('def text():\n  "a b"\n', "",
                                       'def text():\n  "a  b"\n')


if __name__ == "__main__":
    unittest.main()
