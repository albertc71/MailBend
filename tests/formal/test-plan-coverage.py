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
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        if diagnostic:
            self.assertIn(diagnostic, result.stderr)
        return result

    def test_public_plan_requires_a_law_reference(self):
        self.check()
        self.append("src/ops.bend", "\ndef plan_missing() -> List<I.Cmd>:\n  [I.CRead{}]\n")
        self.append("src/tools.bend", "\ndef missing() -> List<I.Cmd>:\n  Ops.plan_missing()\n")
        self.check(1, "plan_missing")

    def test_production_cannot_call_non_plan_command_wrapper(self):
        self.append("src/ops.bend", "\ndef store_cmd() -> List<I.Cmd>:\n  [I.CStore{7}]\n")
        self.append("src/tools.bend", "\ndef bypass() -> List<I.Cmd>:\n  Ops.store_cmd()\n")
        self.check(1, "store_cmd")

    def test_ops_data_cannot_wrap_commands_outside_plan_boundary(self):
        self.append("src/ops.bend", "\ntype Package is Data:\n"
                    "  Package{command: I.Cmd}\n"
                    "def package() -> Package:\n  Package{I.CStore{7}}\n")
        self.append("src/tools.bend", "\ndef bypass() -> Ops.Package:\n"
                    "  Ops.package()\n")
        self.check(1, "command field Package.command")

    def test_canonical_cmd_can_contain_nested_commands(self):
        self.append("src/imap.bend", "  CBatch{commands: List<&2, Cmd>}\n")
        self.check()
        self.append("src/tools.bend", "\ndef bypass() -> I.Cmd:\n  I.CBatch{[]}\n")
        self.check(1, "command I.CBatch")

    def test_imap_data_cannot_wrap_commands_outside_plan_boundary(self):
        self.append("src/imap.bend", "\ntype Package is Data:\n"
                    "  Empty{}\n  Wrapped{commands: List<&2, Cmd>}\n"
                    "def package() -> Package:\n  Wrapped{[CStore{7}]}\n")
        self.append("src/tools.bend", "\ndef bypass() -> I.Package:\n  I.package()\n")
        self.check(1, "command field Package.commands")

    def test_command_field_rejection_does_not_depend_on_a_producer(self):
        self.append("src/ops.bend", "\ntype Hidden is Data:\n"
                    "  Hidden{items: List<&2, I.Cmd>}\n"
                    "type Outer is Data:\n  Outer{inner: Hidden}\n")
        self.check(1, "command field Hidden.items")

    def test_command_fields_use_resolved_aliases_in_both_modules(self):
        for relative in ("src/ops.bend", "src/imap.bend"):
            with self.subTest(relative=relative):
                previous = (self.root / relative).read_text()
                self.append(relative, "\nimport ./imap.bend as Mail\n"
                            "type Package is Data:\n  Package{\n"
                            "    harmless: U32,\n"
                            "    commands: Maybe<&2, List<&2, Mail.Cmd>>\n  }\n")
                self.check(1, "command field Package.commands")
                self.write(relative, previous)

    def test_ops_type_named_cmd_has_no_canonical_exemption(self):
        self.append("src/ops.bend", "\ntype Cmd is Data:\n  Wrapped{command: I.Cmd}\n")
        self.check(1, "command field Cmd.command")

    def test_ops_local_cmd_type_is_not_the_imap_type(self):
        self.append("src/ops.bend", "\ntype Cmd is Data:\n  Local{}\n"
                    "type Package is Data:\n  Package{command: Cmd}\n"
                    "def local() -> Package:\n  Package{Local{}}\n")
        self.append("src/tools.bend", "\ndef local() -> Ops.Package:\n  Ops.local()\n")
        self.check()

    def test_unrelated_cmd_fields_and_recursive_data_are_allowed(self):
        self.write("src/other.bend", "type Cmd is Data:\n  Local{}\n")
        for relative in ("src/ops.bend", "src/imap.bend"):
            self.append(relative, "\nimport ./other.bend as Other\n"
                        "type Package is Data:\n"
                        "  Empty{}\n  Wrapped{Cmd: U32, local: Other.Cmd, next: List<&2, Package>}\n"
                        "def local() -> Package:\n  Empty{}\n")
        self.append("src/tools.bend", "\ndef local() -> Data:\n  (Ops.local(), I.local())\n")
        self.check()

    def test_cmd_text_in_comments_and_literals_is_not_a_field(self):
        self.append("src/ops.bend", "\ntype Package is Data:\n"
                    "  Package{value: U32} # command: I.Cmd\n"
                    "def description() -> String:\n"
                    '  "type Hidden is Data:\\n  Hidden{command: I.Cmd}"\n')
        self.check()

    def test_other_modules_may_keep_command_data(self):
        self.append("src/tools.bend", "\ntype Preview is Data:\n"
                    "  Preview{commands: List<&2, I.Cmd>}\n"
                    "def preview() -> Preview:\n  Preview{Ops.plan_read()}\n")
        self.check()

    def test_imported_command_carriers_remain_outside_the_field_check(self):
        self.write("src/other.bend", "import ./imap.bend as I\n"
                   "type Package is Data:\n  Package{command: I.Cmd}\n")
        self.append("src/ops.bend", "\nimport ./other.bend as Other\n"
                    "type Local is Data:\n  Local{value: Other.Package}\n"
                    "def package() -> Local:\n  Local{Other.Package{I.CRead{}}}\n")
        self.append("src/tools.bend", "\ndef bypass() -> Ops.Local:\n  Ops.package()\n")
        self.check()

    def test_unsupported_data_declarations_fail_closed(self):
        original = (self.root / "src/ops.bend").read_text()
        for declaration in ("type Package<T> is Data:\n  Package{value: T}\n",
                            "type Package is Data:\n",
                            "type Package is Other:\n  Package{value: I.Cmd}\n",
                            "type Package is Data:\n  Package{value}\n",
                            "type Package is Data:\n  Package{value: }\n",
                            "type Package is Data:\n  Package{value: List<I.Cmd}\n",
                            "type Package is Data:\n  Package{value: I.Cmd>}\n",
                            "type Package is Data:\n  Package{value: &item: I.Cmd -> U32}\n",
                            "type Package is Data:\n  Package{value: U32\n"):
            with self.subTest(declaration=declaration):
                self.write("src/ops.bend", original + "\n" + declaration)
                self.check(1, "data")

    def test_production_cannot_call_imap_command_factory(self):
        self.append("src/imap.bend", "\ndef store(uid: U32) -> Cmd:\n  CStore{uid}\n")
        self.append("src/tools.bend", "\ndef bypass() -> I.Cmd:\n  I.store(7)\n")
        self.check(1, "store")

    def test_ops_command_wrapper_requires_a_return_annotation(self):
        self.append("src/ops.bend", "\ndef store_cmd():\n  [I.CStore{7}]\n")
        self.append("src/tools.bend", "\ndef bypass() -> List<I.Cmd>:\n  Ops.store_cmd()\n")
        self.check(1, "missing def return type: store_cmd")

    def test_imap_command_factory_requires_a_return_annotation(self):
        self.append("src/imap.bend", "\ndef store(uid: U32):\n  CStore{uid}\n")
        self.append("src/tools.bend", "\ndef bypass() -> I.Cmd:\n  I.store(7)\n")
        self.check(1, "missing def return type: store")

    def test_other_modules_and_proof_helpers_need_no_return_annotation(self):
        self.append("src/tools.bend", "\ndef untyped_read():\n  Ops.plan_read()\n")
        self.append("LAWS.bend", "\ndef untyped_helper():\n  Ops.plan_read()\n")
        self.write("PROOF.bend", "import ./src/ops.bend as Ops\n"
                   "def untyped_helper():\n  Ops.plan_read()\n")
        self.assertIn("1 public plan", self.check().stdout)

    def test_non_plan_wrapper_cannot_hide_an_internal_plan(self):
        self.append("src/ops.bend", "\ndef plan_hidden() -> List<I.Cmd>:\n  [I.CStore{7}]\n"
                    "\ndef run_hidden() -> List<I.Cmd>:\n  plan_hidden()\n")
        self.append("src/tools.bend", "\ndef bypass() -> List<I.Cmd>:\n  Ops.run_hidden()\n")
        self.check(1, "run_hidden")

    def test_imap_factory_named_plan_is_still_rejected(self):
        self.append("src/imap.bend", "\ndef plan_store(uid: U32) -> Cmd:\n  CStore{uid}\n")
        self.append("src/tools.bend", "\ndef bypass() -> I.Cmd:\n  I.plan_store(7)\n")
        self.check(1, "plan_store")

    def test_cmd_parameters_do_not_make_classifiers_command_producers(self):
        self.append("src/ops.bend", "\ndef observes(cmd: I.Cmd) -> Bool:\n  True{}\n")
        self.append("src/imap.bend", "\ndef observes(cmd: Cmd) -> Bool:\n  True{}\n")
        self.append("src/tools.bend", "\ndef observe(cmd: I.Cmd) -> Bool:\n"
                    "  Ops.observes(cmd) == I.observes(cmd)\n")
        self.check()

    def test_multiline_return_type_uses_actual_imap_alias(self):
        self.append("src/ops.bend", "\nimport ./imap.bend as Mail\n"
                    "def store_cmd(\n  uid: U32\n)\n  -> List<\n    Mail.Cmd\n  >:\n"
                    "  [Mail.CStore{uid}]\n")
        self.append("src/tools.bend", "\nimport ./ops.bend as Plans\n"
                    "def bypass() -> Data:\n  Plans.store_cmd\n")
        self.check(1, "store_cmd")

    def test_unrelated_cmd_return_type_is_allowed(self):
        self.write("src/other.bend", "type Cmd is Data:\n  Local{}\n")
        self.append("src/ops.bend", "\nimport ./other.bend as Other\n"
                    "def local_cmd() -> Other.Cmd:\n  Other.Local{}\n")
        self.append("src/imap.bend", "\nimport ./other.bend as Other\n"
                    "def local_cmd() -> Other.Cmd:\n  Other.Local{}\n")
        self.append("src/tools.bend", "\ndef local() -> Data:\n"
                    "  (Ops.local_cmd(), I.local_cmd())\n")
        self.check()

    def test_ops_cannot_reexport_an_imap_command_factory(self):
        self.append("src/imap.bend", "\ndef store(uid: U32) -> Cmd:\n  CStore{uid}\n")
        self.append("src/ops.bend", "\ndef plan_store() -> I.Cmd:\n  I.store(7)\n")
        self.check(1, "store")

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

    def test_main_and_nested_files_cannot_reference_command_producers(self):
        self.append("src/ops.bend", "\ndef store_cmd() -> I.Cmd:\n  I.CStore{7}\n")
        self.append("src/imap.bend", "\ndef store_cmd() -> Cmd:\n  CStore{7}\n")
        for relative, prefix in (("main.bend", "./src/"), ("src/nested/read.bend", "../")):
            for module in ("ops", "imap"):
                with self.subTest(relative=relative, module=module):
                    path = self.root / relative
                    path.parent.mkdir(exist_ok=True)
                    previous = path.read_text() if path.exists() else None
                    self.write(relative, f"import {prefix}{module}.bend as Mail\n"
                               "def bypass() -> Data:\n  Mail.store_cmd\n")
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

    def test_lexical_colon_inside_pattern_does_not_end_pattern(self):
        # A source-reader control, not a claim that Bend accepts typed patterns.
        self.append("src/tools.bend", "\ndef observe(cmd: Data) -> U32:\n  match cmd:\n"
                    "    case Some{field: I.CStore{uid}}: 0\n")
        self.check()

    def test_new_case_resets_depth_after_malformed_pattern(self):
        self.append("src/tools.bend", "\ndef bypass(cmd: Data) -> I.Cmd:\n  match cmd:\n"
                    "    case Some{\n    case _: I.CStore{7}\n")
        self.check(1, "I.CStore")

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

    def test_existing_import_target_outside_repository_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="mailbend-outside-import-") as directory:
            outside = Path(directory) / "outside.bend"
            outside.write_text("def harmless() -> U32:\n  0\n", encoding="utf-8")
            self.write("src/tools.bend", f"import ../../{outside.parent.name}/outside.bend as Other\n")
            self.check(1, "import does not name a repository file")

    def test_duplicate_definitions_are_rejected(self):
        for relative, declaration in (("src/ops.bend", "\ndef plan_read() -> List<I.Cmd>:\n  []\n"),
                                      ("src/imap.bend", "\ndef observe() -> Bool:\n  True{}\n"
                                       "\ndef observe() -> Bool:\n  False{}\n")):
            with self.subTest(relative=relative):
                previous = (self.root / relative).read_text()
                self.append(relative, declaration)
                self.check(1, "duplicate def")
                self.write(relative, previous)

    def test_duplicate_cmd_constructors_are_rejected(self):
        self.append("src/imap.bend", "  CRead{}\n")
        self.check(1, "duplicate Cmd constructor")

    def test_multiple_cmd_type_declarations_are_rejected(self):
        self.append("src/imap.bend", "\ntype Cmd is Data:\n  CAnother{}\n")
        self.check(1, "Cmd type declaration")

    def test_malformed_law_header_is_rejected_even_with_other_coverage(self):
        self.append("LAWS.bend", "\nlaw malformed = True{}\n")
        self.check(1, "unsupported law declaration")

    def test_tautological_law_satisfies_presence_only_check(self):
        self.write("LAWS.bend", "import ./src/ops.bend as Ops\n"
                   "law tautology:\n  Ops.plan_read == Ops.plan_read\n")
        self.assertIn("1 public plan", self.check().stdout)

    def test_malformed_factory_headers_fail_closed(self):
        for declaration in ("def store(uid: U32 -> Cmd:\n  CStore{uid}\n",
                            "def store() -> :\n  CRead{}\n",
                            "def store() Cmd:\n  CRead{}\n",
                            "def store() -> Cmd\n"):
            with self.subTest(declaration=declaration):
                previous = (self.root / "src/imap.bend").read_text()
                self.append("src/imap.bend", "\n" + declaration)
                self.check(1, "def")
                self.write("src/imap.bend", previous)

    def test_unsupported_return_binders_and_nested_colons_fail_closed(self):
        original = (self.root / "src/ops.bend").read_text()
        for annotation in ("&uid: U32 -> I.Cmd", "@uid: U32 -> I.Cmd",
                           "{I.CRead{} == I.CRead{} : I.Cmd}", "(item: I.Cmd)"):
            with self.subTest(annotation=annotation):
                self.write("src/ops.bend", original +
                           f"\ndef store_cmd() -> {annotation}:\n  I.CRead{{}}\n")
                self.check(1, "unsupported def return type")

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
