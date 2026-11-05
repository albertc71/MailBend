#!/usr/bin/env python3
"""Exercise the plan-coverage command against independent source fixtures."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "tests/formal/check-plan-coverage.py"


class PlanCoverage(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="mailbend-plan-coverage-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "src").mkdir()
        self.write("src/imap.bend", "type Cmd is Data:\n  CRead{}\n  CStore{uid: U32}\n")
        self.write("src/ops.bend", "import ./imap.bend as I\n\n"
                   "def plan_read() -> List<I.Cmd>:\n  [I.CRead{}]\n")
        self.write("src/tools.bend", "import ./ops.bend as Ops\nimport ./imap.bend as I\n\n"
                   "def read() -> List<I.Cmd>:\n  Ops.plan_read()\n")
        self.write("main.bend", "import ./src/tools.bend as Tools\n")
        self.write("LAWS.bend", "import ./src/ops.bend as Ops\nimport ./src/imap.bend as I\n\n"
                   "law read_is_read:\n  Ops.plan_read() == [I.CRead{}]\n")

    def write(self, relative, text):
        (self.root / relative).write_text(text, encoding="utf-8")

    def append(self, relative, text):
        with (self.root / relative).open("a", encoding="utf-8") as out:
            out.write(text)

    def check(self, code=0, diagnostic="", root=None):
        result = subprocess.run([sys.executable, str(CHECK), "--root", str(root or self.root)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        if diagnostic:
            self.assertIn(diagnostic, result.stderr)
        return result

    def test_public_plan_requires_a_law_reference(self):
        self.check()
        self.append("src/ops.bend", "\ndef plan_missing() -> List<I.Cmd>:\n  [I.CRead{}]\n")
        self.append("src/tools.bend", "\ndef missing() -> List<I.Cmd>:\n  Ops.plan_missing()\n")
        self.check(1, "plan_missing")

    def test_production_cannot_construct_commands(self):
        self.append("src/tools.bend", "\ndef bypass() -> I.Cmd:\n  I.CStore{7}\n")
        self.check(1, "src/tools.bend")

    def test_comments_and_strings_do_not_cover_a_plan(self):
        self.write("LAWS.bend", 'import ./src/ops.bend as Ops\n'
                   '# Ops.plan_read()\n'
                   'def description() -> String:\n  "Ops.plan_read()"\n')
        self.check(1, "plan_read")

    def test_constructor_patterns_are_not_constructions(self):
        self.append("src/tools.bend", "\ndef observe(cmd: I.Cmd) -> U32:\n  match cmd:\n"
                    "    case\n      I.CStore{uid}:\n      uid\n"
                    "    case I.CRead{}: 0\n")
        self.check()

    def test_constructor_in_same_line_case_body_is_rejected(self):
        self.append("src/tools.bend", "\ndef bypass(cmd: I.Cmd) -> I.Cmd:\n  match cmd:\n"
                    "    case _: I.CStore{7}\n")
        self.check(1, "I.CStore")

    def test_formatted_aliases_and_function_values_need_coverage(self):
        self.write("src/tools.bend", "  import\t./ops.bend\tas\tPlans # plans\n"
                   "def reader() -> Data:\n  Plans.plan_read\n")
        self.write("LAWS.bend", "\timport ./src/ops.bend as Check # laws\n"
                   "law covered:\n  Check.plan_read() == []\n")
        self.assertIn("1 public plan", self.check().stdout)
        self.write("LAWS.bend", "law uncovered:\n  True{}\n")
        self.check(1, "plan_read")

    def test_unaliased_local_import_fails_closed(self):
        self.write("src/tools.bend", "import ./ops.bend\n"
                   "def reader() -> Data:\n  plan_read()\n")
        self.check(1, "import")

    def test_declaration_text_inside_a_string_is_not_a_definition(self):
        self.append("src/ops.bend", '\ndef description() -> String:\n'
                    '  "first line\ndef plan_read() -> Data:\n  last line"\n')
        self.check()

    def test_dotted_plan_used_outside_ops_requires_coverage(self):
        self.append("src/ops.bend", "\ndef plan_read.extra() -> List<I.Cmd>:\n  []\n")
        self.append("src/tools.bend", "\ndef extra() -> List<I.Cmd>:\n  Ops.plan_read.extra()\n")
        self.check(1, "plan_read.extra")

    def test_new_command_after_blank_lines_is_not_missed(self):
        self.append("src/imap.bend", "\n  NewCommand\n    {uid: U32}\n")
        self.append("src/tools.bend", "\ndef bypass() -> I.Cmd:\n  I.NewCommand{7}\n")
        self.check(1, "I.NewCommand")

    def test_current_repository_passes(self):
        self.check(root=ROOT)

    def test_internal_plans_do_not_need_law_references(self):
        self.append("src/ops.bend", "\ndef plan_internal() -> List<I.Cmd>:\n  []\n"
                    "\ndef plan_read.if() -> List<I.Cmd>:\n  plan_internal()\n")
        self.assertIn("1 public plan", self.check().stdout)

    def test_production_literals_and_comments_do_not_create_references(self):
        self.append("src/ops.bend", "\ndef plan_internal() -> List<I.Cmd>:\n  []\n")
        self.append("src/tools.bend", '# Ops.plan_internal() I.CStore{7}\n'
                    'def words() -> String:\n'
                    '  "escaped \\" quote # Ops.plan_internal() I.CStore{7} and \\\\"\n'
                    "def quote() -> U32:\n  '\\''\n"
                    "def hash() -> U32:\n  '#'\n")
        self.assertIn("1 public plan", self.check().stdout)

    def test_full_plan_identifier_is_required(self):
        self.write("LAWS.bend", "import ./src/ops.bend as Ops\n"
                   "law different:\n  Ops.plan_read.extra() == []\n")
        self.check(1, "plan_read")

    def test_unrelated_modules_do_not_cover_plans(self):
        self.write("src/other.bend", "def plan_read() -> Data:\n  True{}\n")
        self.write("LAWS.bend", "import ./src/other.bend as Ops\n"
                   "law different:\n  Ops.plan_read() == True{}\n")
        self.check(1, "plan_read")

    def test_qualified_binding_cannot_supply_plan_coverage(self):
        for body in ("def unrelated(Ops.plan_read: U32) -> U32:\n  0\n",
                     "def unrelated(Ops.plan_read):\n  0\n",
                     "def unrelated<Ops.plan_read>() -> U32:\n  0\n",
                     "type Unrelated<Ops.plan_read> is Data:\n  Example{}\n",
                     "type Unrelated is Data:\n  Example{Ops.plan_read: U32}\n",
                     "def Ops.plan_read() -> U32:\n  0\n",
                     "law unrelated:\n  for Ops.plan_read: U32\n  True{}\n",
                     "law unrelated:\n  exs Ops.plan_read: U32\n  True{}\n",
                     "law unrelated:\n  @Ops.plan_read: U32 -> U32\n",
                     "law unrelated:\n  &Ops.plan_read: U32 ** U32\n",
                     "law unrelated:\n  -Ops.plan_read = 0\n  True{}\n",
                     "law Ops.plan_read:\n  True{}\n",
                     "def unrelated() -> Data:\n  Ops.plan_read => 0\n",
                     "def unrelated() -> U32:\n  Ops.plan_read = 0\n  0\n",
                     "def unrelated() -> U32:\n  Ops.plan_read x = 0 1\n  x\n",
                     "def unrelated() -> U32:\n  (Ops.plan_read, x) = (0, 1)\n  x\n",
                     "def unrelated() -> U32:\n  (\n    Ops.plan_read,\n    x\n  ) = (0, 1)\n  x\n",
                     "def unrelated(cmd: Data) -> U32:\n  match cmd:\n"
                     "    case Some{Ops.plan_read}: 0\n"):
            with self.subTest(body=body):
                self.write("LAWS.bend", "import ./src/ops.bend as Ops\n" + body)
                self.check(1, "plan_read")

    def test_helper_body_is_not_a_law_reference(self):
        for prefix in ("", "law unrelated:\n  True{}\n@unsafe ",
                       "law unrelated: True{} ", "law unrelated:\n  True{}\n"):
            with self.subTest(prefix=prefix):
                self.write("LAWS.bend", "import ./src/ops.bend as Ops\n" + prefix +
                           "def helper() -> Data:\n  Ops.plan_read()\n")
                self.check(1, "plan_read")

    def test_function_value_equality_is_a_law_reference(self):
        self.write("LAWS.bend", "import ./src/ops.bend as Ops\n"
                   "law compared:\n  Ops.plan_read == another_function\n")
        self.check()

    def test_main_and_nested_production_files_are_checked(self):
        for relative, imap in (("main.bend", "./src/imap.bend"),
                               ("src/nested/read.bend", "../imap.bend")):
            with self.subTest(relative=relative):
                path = self.root / relative
                path.parent.mkdir(exist_ok=True)
                previous = path.read_text() if path.exists() else None
                self.write(relative, f"import {imap} as Mail\n"
                           "def bypass() -> Mail.Cmd:\n  Mail.CStore{7}\n")
                self.check(1, relative)
                if previous is None:
                    path.unlink()
                else:
                    self.write(relative, previous)

    def test_patterns_can_contain_nested_constructors(self):
        self.append("src/tools.bend", "\ndef observe(cmd: Data) -> U32:\n  match cmd:\n"
                    "    case Some{I.CStore{uid}} <> rest:\n      uid\n"
                    "    case Some{I.CRead{}}: 0\n")
        self.check()

    def test_pattern_does_not_hide_following_constructor(self):
        self.append("src/tools.bend", "\ndef bypass(cmd: I.Cmd) -> I.Cmd:\n  match cmd:\n"
                    "    case I.CRead{}: I.CStore\n      {7}\n")
        self.check(1, "I.CStore")

    def test_unrelated_constructor_is_allowed(self):
        self.write("src/other.bend", "type Other is Data:\n  CStore{uid: U32}\n")
        self.append("src/tools.bend", "\nimport ./other.bend as Other\n"
                    "def unrelated() -> Other.Other:\n  Other.CStore{7}\n")
        self.check()

    def test_unsupported_and_unresolved_imports_fail_closed(self):
        for declaration in ("import ./ops.bend exposing plan_read", "import ./missing.bend as Ops",
                            "import ../outside.bend as Ops", "import ./ops.bend as Ops\n"
                            "import ./imap.bend as Ops",
                            "def unrelated() -> U32: 0 import ./imap.bend as I\n"
                            "def bypass() -> I.Cmd: I.CStore{7}"):
            with self.subTest(declaration=declaration):
                self.write("src/tools.bend", declaration + "\n")
                self.check(1, "import")

    def test_unterminated_literals_fail_closed(self):
        for literal in ('"unfinished', "'unfinished"):
            with self.subTest(literal=literal):
                self.write("src/tools.bend", literal)
                self.check(1, "unterminated literal")

    def test_malformed_plan_and_command_declarations_fail_closed(self):
        self.append("src/ops.bend", "\ndef plan_broken = []\n")
        self.check(1, "def declaration")
        self.write("src/ops.bend", "def plan_read() -> Data:\n  []\n")
        for declaration in ("type Cmd is Data:\n", "type Cmd is Other:\n  CRead{}\n",
                            "type Cmd is Data:\n  CRead{\n", "type Cmd is Data:\n  CRead\n"):
            with self.subTest(declaration=declaration):
                self.write("src/imap.bend", declaration)
                self.check(1, "Cmd")


if __name__ == "__main__":
    unittest.main()
