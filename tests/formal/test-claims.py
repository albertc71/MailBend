#!/usr/bin/env python3
"""Negative controls for claim drift and mutation-result classification; no Bend required."""

import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from law_catalogue import (bend_headers, catalogue, laws, generated, load_json, proof_files,
                           python_headers, reference, reference_location)
from mutation_runner import require_baseline, require_rejection, run_mutations

SPEC = importlib.util.spec_from_file_location("claim_checks", ROOT / "tools/check-claims.py")
CHECKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKS)

IMPORT_FORMS = (
    'import {path} as Other',
    '  import {path} as Other',
    'import {path} as Other # observer module',
    '\timport\t{path}\tas\tOther\t# observer module',
    ' import {path} as Other  ',
)

DEFINITION_FORMS = (
    '@unsafe def {name}() -> Bool:\n  True{{}}\n',
    '  @unsafe\tdef\t{name}() -> Bool:\n    True{{}}\n',
    '@unsafe\ndef {name}() -> Bool:\n  True{{}}\n',
    '  def {name}() -> Bool:\n    True{{}}\n',
    'def\t{name}() -> Bool:\n  True{{}}\n',
    'def\n{name}() -> Bool:\n  True{{}}\n',
    'def {name}\n() -> Bool:\n  True{{}}\n',
)


def add_observer_import(root, declaration, name, transitive):
    """Reach the collision directly or through a differently formatted import."""
    (root / 'tests/formal').mkdir(parents=True, exist_ok=True)
    (root / 'tests/formal/other-observer.bend').write_text(
        f'def {name}() -> Bool:\n  True{{}}\n')
    if transitive:
        (root / 'tests/formal/observer-bridge.bend').write_text(
            declaration.format(path='./other-observer.bend') + '\n')
        declaration = '  import ./tests/formal/observer-bridge.bend as Bridge # transitive'
    else:
        declaration = declaration.format(path='./tests/formal/other-observer.bend')
    with (root / 'PROOF.bend').open('a') as out:
        out.write('\n' + declaration + '\n')


class Claims(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="mailbend-claims-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for folder in ("src", "tests", "docs", "native"):
            shutil.copytree(ROOT / folder, self.root / folder,
                            ignore=shutil.ignore_patterns("target", "__pycache__", ".audit"))
        for name in ("README.md", "LAWS.bend", "PROOF.bend"):
            shutil.copy2(ROOT / name, self.root / name)
        self.manifest = json.loads((self.root / "docs/safety-claims.json").read_text())

    def save(self):
        (self.root / "docs/safety-claims.json").write_text(json.dumps(self.manifest))

    def replace(self, path, before, after):
        target = self.root / path
        source = target.read_text()
        self.assertIn(before, source)
        target.write_text(source.replace(before, after))

    def rejected(self, message):
        self.save()
        with self.assertRaisesRegex(ValueError, message):
            CHECKS.validate(self.root)

    def test_current_catalogue_and_coverage(self):
        generated(self.root / "docs/LAWS.md", catalogue(self.root), True)
        generated(self.root / "docs/PROOF-COVERAGE.md", CHECKS.coverage(self.root), True)

    def test_every_declaration_in_catalogue_once(self):
        records, _ = CHECKS.validate(self.root)
        result = catalogue(self.root)
        self.assertIn(f"**{len(records)} laws**", result)
        for name in records:
            self.assertEqual(result.count(f"[`{name}`]"), 1)
        self.assertEqual(records['part_writes_nothing'].summary,
                         'Fetching a selected MIME part changes no mailbox.')

    def test_generated_catalogue_stale(self):
        with self.assertRaisesRegex(ValueError, "stale generated"):
            generated(self.root / "docs/LAWS.md", catalogue(self.root) + "stale", True)

    def test_generated_coverage_stale(self):
        with self.assertRaisesRegex(ValueError, "stale generated"):
            generated(self.root / "docs/PROOF-COVERAGE.md", CHECKS.coverage(self.root) + "stale", True)

    def test_renamed_law(self):
        self.replace("LAWS.bend", "law probe_writes_nothing:", "law renamed_probe:")
        self.rejected("missing law probe_writes_nothing")

    def test_new_unclaimed_law(self):
        with (self.root / "LAWS.bend").open("a") as out:
            out.write("\n# LAW: a new claim must be assigned explicitly\nlaw future_safety:\n  {True{} == True{} : Bool}\n")
        self.rejected("laws without a claim or explicit exclusion.*future_safety")

    def test_missing_summary(self):
        self.replace("LAWS.bend", "# LAW: mail_get is read-only", "# A comment, not a LAW summary")
        self.rejected("read_is_read_only needs a source or supplemental summary")

    def test_stale_supplement(self):
        path = self.root / "docs/law-summaries.json"
        data = json.loads(path.read_text())
        data['gone_law'] = 'No such law.'
        path.write_text(json.dumps(data))
        self.rejected("unused law summaries.*gone_law")

    def test_missing_test(self):
        self.manifest['claims'][0]['tests'] = ['tests/test-e2e.py#does_not_exist']
        self.rejected("missing test name")

    def test_ambiguous_python_test_rejected_by_validation_and_coverage(self):
        (self.root / 'tests/ambiguous.py').write_text(
            'class A:\n    def test_x(self): pass\n'
            'class B:\n    async def test_x(self): pass\n')
        self.manifest['claims'][0]['tests'] = ['tests/ambiguous.py#test_x']
        self.rejected('ambiguous test reference: tests/ambiguous.py#test_x; '
                      'declarations or bindings at lines 2, 4')
        with self.assertRaisesRegex(ValueError, 'ambiguous test reference'):
            CHECKS.coverage(self.root)

    def test_python_rebinding_rejected_by_validation_and_coverage(self):
        for binding in ('class test_x: pass', 'test_x = None', 'test_x: object = None'):
            with self.subTest(binding=binding):
                (self.root / 'tests/rebound.py').write_text(
                    'def test_x(): pass\n' + binding + '\n')
                self.manifest['claims'][0]['tests'] = ['tests/rebound.py#test_x']
                message = ('ambiguous test reference: tests/rebound.py#test_x; '
                           'declarations or bindings at lines 1, 2')
                self.rejected(message)
                with self.assertRaisesRegex(ValueError, message):
                    CHECKS.coverage(self.root)

    def test_class_assignment_rejected_by_public_checker(self):
        path = self.root / 'tests/rebound.py'
        self.manifest['claims'][0]['tests'] = ['tests/rebound.py#test_x']
        self.save()
        for binding in ('test_x = None', 'test_x: object = None',
                        'test_x = other = None', 'test_x = test_x = None'):
            with self.subTest(binding=binding):
                path.write_text('class Example:\n    def test_x(self): pass\n'
                                '    ' + binding + '\n')
                message = ('ambiguous test reference: tests/rebound.py#test_x; '
                           'declarations or bindings at lines 2, 3')
                self.rejected(message)
                with self.assertRaisesRegex(ValueError, message):
                    CHECKS.coverage(self.root)
                result = subprocess.run([sys.executable, str(ROOT / 'tools/check-claims.py'),
                                         '--root', str(self.root), '--check'],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr.strip(), message)

        # Removing the class store, without changing the reference, restores a valid link.
        # Annotation-only and ordinary method-local assignments must stay acceptable.
        path.write_text('class Example:\n    def test_x(self): pass\n'
                        '    test_x: object\n    def helper(self):\n        test_x = None\n')
        generated(self.root / 'docs/PROOF-COVERAGE.md', CHECKS.coverage(self.root), False)
        result = subprocess.run([sys.executable, str(ROOT / 'tools/check-claims.py'),
                                 '--root', str(self.root), '--check'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('../tests/rebound.py#L2', (self.root / 'docs/PROOF-COVERAGE.md').read_text())

    def test_missing_code(self):
        self.manifest['claims'][0]['code'] = ['src/ops.bend#does_not_exist']
        self.rejected("missing code name")

    def test_missing_law_proof(self):
        self.replace('PROOF.bend', 'def Laws.probe_writes_nothing(', 'def obsolete_probe(')
        self.rejected("missing root proof probe_writes_nothing")

    def test_duplicate_claim(self):
        self.manifest['claims'].append(copy.deepcopy(self.manifest['claims'][0]))
        self.rejected("duplicate claim")

    def test_missing_mutation(self):
        del self.manifest['claims'][0]['mutation']
        self.rejected("proven claim needs a mutation")

    def test_stale_mutation(self):
        self.manifest['claims'][0]['mutation']['before'] = 'not production source'
        self.rejected("mutation target must occur exactly once")

    def test_duplicate_mutation_target(self):
        before = self.manifest['claims'][0]['mutation']['before']
        with (self.root / 'src/ops.bend').open('a') as out:
            out.write('\n# ' + before)
        self.rejected("mutation target must occur exactly once")

    def test_noop_mutation(self):
        mutation = self.manifest['claims'][0]['mutation']
        mutation['after'] = mutation['before']
        self.rejected("invalid mutation replacement")

    def test_no_law_mutation(self):
        self.manifest['claims'][0]['mutation']['path'] = 'LAWS.bend'
        self.rejected("mutations may target only production")

    def test_path_escape(self):
        self.manifest['claims'][0]['code'] = ['../outside.bend']
        self.rejected("path outside repository")

    def test_unreachable_proof(self):
        (self.root / 'tests/formal/not-imported.bend').write_text('def unrelated() -> Bool:\n  True{}\n')
        self.manifest['claims'][0]['mutation']['proof'] = 'tests/formal/not-imported.bend#unrelated'
        self.rejected("mutation proof is not reachable")

    def test_bad_anchor(self):
        self.manifest['claims'][0]['anchor'] = 'no-such-heading'
        self.rejected("missing README anchor")

    def test_anchor_must_contain_claim_marker(self):
        self.manifest['claims'][0]['anchor'] = 'license'
        self.rejected("marker not in declared README section")

    def test_fenced_markers_do_not_count(self):
        self.replace('README.md', '<!-- claim:dry-run -->', '')
        with (self.root / 'README.md').open('a') as out:
            out.write('\n```html\n<!-- claim:dry-run -->\n```\n')
        self.rejected("claims without README marker.*dry-run")

    def test_fenced_headings_do_not_count(self):
        self.manifest['claims'][0]['anchor'] = 'fake-heading'
        with (self.root / 'README.md').open('a') as out:
            out.write('\n~~~md\n## Fake heading\n~~~\n')
        self.rejected("missing README anchor")

    def test_mutation_must_touch_cited_code(self):
        self.manifest['claims'][0]['code'] = ['src/imap.bend']
        self.rejected("mutation target is not cited claim code")

    def test_mutation_must_reject_a_cited_root_law(self):
        self.manifest['claims'][0]['mutation']['law'] = 'read_is_read_only'
        self.rejected("mutation rejects an uncited law")

    def test_direct_observer_must_implement_linked_law(self):
        self.manifest['claims'][0]['mutation']['law'] = 'probe_writes_nothing'
        self.rejected("mutation observer and law disagree")

    def test_helper_observer_needs_cited_law(self):
        claim = next(c for c in self.manifest['claims'] if c['id'] == 'client-prompts')
        claim['mutation']['law'] = 'read_is_read_only'
        self.rejected("mutation rejects an uncited law")

    def test_example_observer_needs_cited_law(self):
        claim = next(c for c in self.manifest['claims'] if c['id'] == 'role-resolution')
        claim['mutation']['law'] = 'tests/formal/role-folders.bend#missing'
        self.rejected("mutation rejects an uncited law")

    def test_observer_needs_relationship_explanation(self):
        self.manifest['claims'][0]['mutation']['observer_reason'] = '  '
        self.rejected("mutation observer needs a relationship explanation")

    def test_same_named_reachable_observer_is_ambiguous(self):
        original = (self.root / 'PROOF.bend').read_text()
        for declaration in IMPORT_FORMS:
            for transitive in (False, True):
                with self.subTest(declaration=declaration, transitive=transitive):
                    (self.root / 'PROOF.bend').write_text(original)
                    add_observer_import(self.root, declaration, 'plan_quota_writes_nothing',
                                        transitive)
                    self.rejected("ambiguous mutation observer")

    def test_unknown_import_syntax_fails_closed(self):
        with (self.root / 'PROOF.bend').open('a') as out:
            out.write('\n  import ./tests/formal/other-observer.bend as Other extra\n')
        self.rejected("unsupported Bend import")

    def test_reachable_observer_declaration_whitespace_is_ambiguous(self):
        add_observer_import(self.root, IMPORT_FORMS[0], 'plan_quota_writes_nothing', False)
        path = self.root / 'tests/formal/other-observer.bend'
        for definition in DEFINITION_FORMS:
            with self.subTest(definition=definition):
                path.write_text(definition.format(name='plan_quota_writes_nothing'))
                self.rejected("ambiguous mutation observer")

    def test_unknown_observer_declaration_syntax_fails_closed(self):
        add_observer_import(self.root, IMPORT_FORMS[0], 'plan_quota_writes_nothing', False)
        (self.root / 'tests/formal/other-observer.bend').write_text(
            'def # unsupported comment between declaration tokens\n'
            'plan_quota_writes_nothing() -> Bool:\n  True{}\n')
        self.rejected("unsupported Bend def declaration")

    def test_unsupported_attributes_fail_closed(self):
        add_observer_import(self.root, IMPORT_FORMS[0], 'plan_quota_writes_nothing', False)
        path = self.root / 'tests/formal/other-observer.bend'
        for source in ('@unknown def hidden() -> Bool: True{}\n',
                       '@unsafe # unsupported intervening comment\ndef hidden(): True{}\n',
                       '@unsafe @unsafe def hidden(): True{}\n', '@unsafe\n'):
            with self.subTest(source=source):
                path.write_text(source)
                self.rejected("unsupported Bend attribute/header")

    def test_foreign_effect_import_has_explicit_scope_diagnostic(self):
        with (self.root / 'PROOF.bend').open('a') as out:
            out.write('\ndef effect() -> IO(Bool):\n  import "./effect.c"\n')
        self.rejected("only Base and repository-local.*not foreign effect-body imports")

    def test_law_whitespace_is_catalogued_and_linked(self):
        path = self.root / 'LAWS.bend'
        original = path.read_text()
        for header in ('  law probe_writes_nothing:', 'law\tprobe_writes_nothing :',
                       'law\nprobe_writes_nothing\n:'):
            with self.subTest(header=header):
                path.write_text(original.replace('law probe_writes_nothing:', header))
                records = laws(self.root)
                number = original[:original.index('law probe_writes_nothing:')].count('\n') + 1
                self.assertEqual(records['probe_writes_nothing'].line, number)
                self.assertIn(f'../LAWS.bend#L{number}', catalogue(self.root))
                CHECKS.coverage(self.root)
                self.assertIn(f'#L{number}', CHECKS.link(
                    'LAWS.bend#probe_writes_nothing', 'law', records, self.root))

    def test_unknown_law_header_is_not_silently_omitted(self):
        with (self.root / 'LAWS.bend').open('a') as out:
            out.write('\nlaw\tfuture? :\n  Bool\n')
        self.rejected("unsupported Bend law declaration")

    def test_definition_links_share_header_positions(self):
        path = self.root / 'src/link-fixture.bend'
        for definition in DEFINITION_FORMS + ('def {name}:\n  True{{}}\n',):
            with self.subTest(definition=definition):
                path.write_text('# heading\n\n' + definition.format(name='fixture'))
                self.assertEqual(bend_headers(path, 'def'), {'fixture': 3})
                self.assertEqual(CHECKS.link('src/link-fixture.bend#fixture', 'code', {}, self.root),
                                 '[`src/link-fixture.bend#fixture`](../src/link-fixture.bend#L3)')

    def test_multiple_unsafe_headers_keep_absolute_offsets_and_lines(self):
        path = self.root / 'src/link-fixture.bend'
        path.write_text('# heading\n\n@unsafe def first():\n  True{}\n\n'
                        '  @unsafe\ndef second():\n  True{}\n\n'
                        '@unsafe\tdef third():\n  True{}\n')
        self.assertEqual(bend_headers(path, 'def'), {'first': 3, 'second': 6, 'third': 10})
        for name, line in (('first', 3), ('second', 6), ('third', 10)):
            self.assertIn(f'#L{line})', CHECKS.link(
                f'src/link-fixture.bend#{name}', 'code', {}, self.root))

    def test_python_links_follow_ast_positions(self):
        (self.root / 'tests/link-fixture.py').write_text('async def\tfixture(\n):\n    pass\n')
        self.assertIn('#L1)', CHECKS.link('tests/link-fixture.py#fixture', 'test', {}, self.root))

    def test_missing_link_name_reports_value_error(self):
        with self.assertRaisesRegex(ValueError, 'missing code name'):
            CHECKS.link('src/ops.bend#does_not_exist', 'code', {}, self.root)

    def test_import_comments_are_not_dependencies(self):
        with (self.root / 'PROOF.bend').open('a') as out:
            out.write('\n  # import ./missing.bend as Missing\n')
        CHECKS.validate(self.root)

    def test_same_named_unreachable_observer_is_not_ambiguous(self):
        path = self.root / 'tests/formal/other-observer.bend'
        path.write_text('def plan_quota_writes_nothing() -> Bool:\n  True{}\n')
        CHECKS.validate(self.root)

    def test_summary_markers_cover_the_summarized_claims(self):
        # This is a specific regression guard, not a semantic prose classifier.
        lines = [line for line in (self.root / 'README.md').read_text().splitlines()
                 if line.startswith('with pure-function safety rules')
                 or line.startswith('- **Pure-function safety rules')]
        self.assertEqual(len(lines), 2)
        expected = {'read-plans', 'move-delete-plans', 'send-allowlist', 'jev-gates'}
        for line in lines:
            self.assertTrue(expected <= set(CHECKS.MARKER.findall(line)))

    def test_read_safety_includes_brief_and_contacts(self):
        claim = next(c for c in self.manifest['claims'] if c['id'] == 'read-plans')
        self.assertTrue({'brief_plans_write_nothing', 'brief_range_writes_nothing',
                         'contact_plans'} <= set(claim['laws']))

    def test_unknown_marker(self):
        with (self.root / 'README.md').open('a') as out:
            out.write('\n<!-- claim:unknown -->\n')
        self.rejected("README marker without entry")

    def test_missing_marker(self):
        self.replace('README.md', '<!-- claim:dry-run -->', '')
        self.rejected("claims without README marker.*dry-run")

    def test_malformed_marker(self):
        with (self.root / 'README.md').open('a') as out:
            out.write('\n<!-- claim:dry-run-->\n')
        self.rejected("malformed claim marker")

    def test_unmarked_proven_sentence(self):
        with (self.root / 'README.md').open('a') as out:
            out.write('\nAll behavior is proven.\n')
        self.rejected("proven statement needs a proven claim marker")

    def test_tested_marker_cannot_support_proven(self):
        with (self.root / 'README.md').open('a') as out:
            out.write('\nAll TLS is proven. <!-- claim:native-boundaries -->\n')
        self.rejected("proven statement needs a proven claim marker")

    def test_claimed_and_excluded(self):
        self.manifest['unclaimed']['probe_writes_nothing'] = 'Not needed.'
        self.rejected("law both claimed and unclaimed")

    def test_exclusion_needs_reason(self):
        name = next(iter(self.manifest['unclaimed']))
        self.manifest['unclaimed'][name] = ''
        self.rejected("needs a reason")

    def test_no_implicit_exclusion(self):
        self.manifest['unclaimed'].clear()
        self.rejected("laws without a claim or explicit exclusion")

    def test_duplicate_json_keys(self):
        path = self.root / 'bad.json'
        path.write_text('{"claims": [], "claims": []}')
        with self.assertRaisesRegex(ValueError, "duplicate key"):
            load_json(path)


class PythonReferences(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix='mailbend-python-reference-test-')
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.path = self.root / 'fixture.py'

    def rejected(self, source, lines):
        self.path.write_text(source)
        value = 'fixture.py#test_x'
        message = (f'ambiguous test reference: {value}; declarations or bindings at lines '
                   + ', '.join(map(str, sorted(set(lines)))))
        self.assertEqual(python_headers(self.path)['test_x'], tuple(lines))
        cache = {}
        # The second validation uses the cached reader output, not a fresh AST.
        for _ in range(2):
            with self.assertRaises(ValueError) as error:
                reference(self.root, value, 'test', cache)
            self.assertEqual(str(error.exception), message)
        with self.assertRaises(ValueError) as error:
            CHECKS.link(value, 'test', {}, self.root)
        self.assertEqual(str(error.exception), message)

    def test_duplicate_sync_functions_rejected(self):
        self.rejected('def test_x(): pass\ndef test_x(): pass\n', (1, 2))

    def test_duplicate_async_functions_rejected(self):
        self.rejected('async def test_x(): pass\nasync def test_x(): pass\n', (1, 2))

    def test_mixed_sync_async_functions_rejected(self):
        self.rejected('def test_x(): pass\nasync def test_x(): pass\n', (1, 2))

    def test_same_named_methods_in_different_classes_rejected(self):
        self.rejected('class A:\n    def test_x(self): pass\n'
                      'class B:\n    def test_x(self): pass\n', (2, 4))

    def test_nested_and_module_functions_rejected_in_source_order(self):
        # ast.walk visits the module def before the earlier nested one.
        self.rejected('def outer():\n    def test_x(): pass\n'
                      'def test_x(): pass\n', (2, 3))

    def test_repeated_nested_functions_rejected(self):
        self.rejected('def first():\n    async def test_x(): pass\n'
                      'def second():\n    def test_x(): pass\n', (2, 4))

    def test_class_function_collisions_rejected_in_either_order(self):
        for function in ('def test_x(): pass', 'async def test_x(): pass'):
            for source in (function + '\nclass test_x: pass\n',
                           'class test_x: pass\n' + function + '\n'):
                with self.subTest(source=source):
                    self.rejected(source, (1, 2))

    def test_nested_class_function_collision_rejected(self):
        self.rejected('def outer():\n    class test_x: pass\n'
                      'def test_x(): pass\n', (2, 3))

    def test_module_assignments_rejected_in_either_order(self):
        for binding in ('test_x = None', 'test_x: object = None',
                        'other = test_x = None', 'test_x = other = None',
                        '(other, test_x) = (1, 2)',
                        '[other, *test_x] = [1, 2]',
                        '(other, [test_x]) = (1, [2])'):
            for source in ('def test_x(): pass\n' + binding + '\n',
                           binding + '\ndef test_x(): pass\n'):
                with self.subTest(source=source):
                    self.rejected(source, (1, 2))

    def test_class_assignments_rejected_in_either_order(self):
        for function in ('def test_x(self): pass', 'async def test_x(self): pass'):
            for binding in ('test_x = None', 'test_x: object = None',
                            'other = test_x = None', 'test_x = other = None',
                            '(other, test_x) = (1, 2)', '[other, *test_x] = [1, 2]'):
                for body in (function + '\n    ' + binding, binding + '\n    ' + function):
                    with self.subTest(body=body):
                        self.rejected('class Example:\n    ' + body + '\n', (2, 3))

    def test_class_control_flow_assignments_rejected(self):
        for binding in ('test_x = None', 'test_x: object = None'):
            with self.subTest(binding=binding):
                self.rejected('class Example:\n    def test_x(self): pass\n'
                              '    if enabled:\n        ' + binding + '\n', (2, 4))

    def test_class_assignments_count_file_wide_once(self):
        for prefix in ('class Outer:', 'def outer():', 'async def outer():'):
            with self.subTest(prefix=prefix):
                self.rejected('def test_x(): pass\n' + prefix + '\n'
                              '    class Inner:\n        test_x = None\n', (1, 4))
        self.rejected('def test_x(): pass\nclass Other:\n    test_x = None\n', (1, 3))

    def test_repeated_target_lines_are_only_deduplicated_in_diagnostic(self):
        for source, lines in (
                ('def test_x(): pass\ntest_x = test_x = None\n', (1, 2, 2)),
                ('class Example:\n    def test_x(self): pass\n'
                 '    test_x = test_x = None\n', (2, 3, 3))):
            with self.subTest(source=source):
                self.rejected(source, lines)

    def test_cached_same_line_collisions_remain_ambiguous(self):
        self.path.write_text('def test_x(): pass\n')
        cache = {(self.path, 'test'): {'test_x': (1, 1)}}
        with self.assertRaisesRegex(ValueError, 'declarations or bindings at lines 1$'):
            reference_location(self.root, 'fixture.py#test_x', 'test', cache)

    def test_module_control_flow_assignments_rejected(self):
        for binding in ('test_x = None', 'test_x: object = None'):
            with self.subTest(binding=binding):
                self.rejected('def test_x(): pass\nif enabled:\n    ' + binding + '\n',
                              (1, 3))

    def test_multiline_assignment_reports_target_line(self):
        self.rejected('def test_x(): pass\n(\n    other,\n    test_x,\n) = (1, 2)\n',
                      (1, 4))

    def test_local_stores_and_nonbinding_targets_do_not_reject_test(self):
        self.path.write_text(
            'def test_x(): pass\n'
            'test_x: object\n'
            'thing.test_x = None\nthing[test_x] = None\n'
            'thing.test_x: object = None\nthing[test_x]: object = None\n'
            'def helper():\n    test_x = None\n'
            '    test_x: object = None\n'
            'async def async_helper():\n    test_x = None\n'
            'class Example:\n    test_x: object\n'
            '    thing.test_x = None\n    thing[test_x] = None\n'
            '    def method(self):\n        test_x = None\n'
            '        test_x: object = None\n'
            '    async def async_method(self):\n        test_x = None\n')
        self.assertEqual(python_headers(self.path)['test_x'], (1,))
        self.assertEqual(reference_location(self.root, 'fixture.py#test_x', 'test'),
                         ('fixture.py', 'test_x', 1))
        self.assertIn('#L1)', CHECKS.link('fixture.py#test_x', 'test', {}, self.root))

    def test_uncited_class_and_assignment_collisions_do_not_reject_test(self):
        self.path.write_text('def helper(): pass\nclass helper: pass\n'
                             'helper = None\nhelper: object = None\n'
                             'def test_x(): pass\n')
        cache = {}
        self.assertEqual(reference_location(self.root, 'fixture.py#test_x', 'test', cache),
                         ('fixture.py', 'test_x', 5))
        self.assertIn('#L5)', CHECKS.link('fixture.py#test_x', 'test', {}, self.root))
        with self.assertRaisesRegex(ValueError, 'ambiguous test reference'):
            reference(self.root, 'fixture.py#helper', 'test', cache)

    def test_unique_function_forms_preserve_declaration_lines(self):
        self.path.write_text(
            '# heading\n@decorator\ndef sync_test(): pass\n\n'
            '@decorator\nasync def\tasync_test(\n):\n    pass\n\n'
            'class Example:\n    @decorator\n    def method(self): pass\n'
            '    @decorator\n    async def async_method(self): pass\n\n'
            'def outer():\n    @decorator\n    def nested(): pass\n'
            '    @decorator\n    async def async_nested(): pass\n')
        expected = {'sync_test': (3,), 'async_test': (6,), 'method': (12,),
                    'async_method': (14,), 'outer': (16,), 'nested': (18,),
                    'async_nested': (20,)}
        self.assertEqual(python_headers(self.path), expected)
        cache = {}
        for name, (line,) in expected.items():
            value = f'fixture.py#{name}'
            with self.subTest(name=name):
                self.assertEqual(reference(self.root, value, 'test', cache), ('fixture.py', name))
                self.assertEqual(reference_location(self.root, value, 'test', cache),
                                 ('fixture.py', name, line))
                self.assertEqual(CHECKS.link(value, 'test', {}, self.root),
                                 f'[`{value}`](../fixture.py#L{line})')

    def test_uncited_duplicate_helpers_do_not_reject_unique_test(self):
        self.path.write_text('class A:\n    def helper(self): pass\n'
                             'class B:\n    def helper(self): pass\n'
                             'def test_x(): pass\n')
        cache = {}
        self.assertEqual(reference(self.root, 'fixture.py#test_x', 'test', cache),
                         ('fixture.py', 'test_x'))
        self.assertIn('#L5)', CHECKS.link('fixture.py#test_x', 'test', {}, self.root))
        # A cache populated by a valid name must still reject an ambiguous name.
        with self.assertRaisesRegex(ValueError, 'ambiguous test reference'):
            reference(self.root, 'fixture.py#helper', 'test', cache)

    def test_nonfunction_names_do_not_become_reference_targets(self):
        self.path.write_text('# def test_x(): pass\ntext = "def test_x(): pass"\n'
                             'test_x = lambda: None\ntest_x: object = None\nclass test_x: pass\n')
        self.assertEqual(python_headers(self.path), {})
        with self.assertRaisesRegex(ValueError, 'missing test name: fixture.py#test_x'):
            reference(self.root, 'fixture.py#test_x', 'test')
        with self.assertRaisesRegex(ValueError, 'missing test name: fixture.py#test_x'):
            CHECKS.link('fixture.py#test_x', 'test', {}, self.root)


class Mutations(unittest.TestCase):
    mutation = dict(id='fixture', path='src/model.bend', before='safe', after='broken',
                    proof='PROOF.bend#Laws.fixture')

    @staticmethod
    def result(code=1, text='SOME PROOFS FAIL\nLocation: Laws.fixture\n- expected : True\n- observed : False\n'):
        return subprocess.CompletedProcess([], code, text, '')

    def test_semantic_rejection(self):
        root = self.fixture()
        require_rejection(self.result(), self.mutation, root)
        require_rejection(self.result(text='SOME PROOFS FAIL\nLocation: fixture\n- expected : True\n- observed : False\n'), self.mutation, root)

    def test_rejection_cannot_select_same_name_in_another_file(self):
        for declaration in IMPORT_FORMS:
            for transitive in (False, True):
                with self.subTest(declaration=declaration, transitive=transitive):
                    root = self.fixture()
                    add_observer_import(root, declaration, 'fixture', transitive)
                    with self.assertRaisesRegex(ValueError, 'ambiguous mutation observer'):
                        require_rejection(self.result(), self.mutation, root)

    def test_runner_rejects_ambiguous_observer_before_running_bend(self):
        def unexpected_check(path):
            self.fail('an ambiguous observer must fail before a proof check')
        for declaration in IMPORT_FORMS:
            for transitive in (False, True):
                with self.subTest(declaration=declaration, transitive=transitive):
                    root = self.fixture()
                    add_observer_import(root, declaration, 'Laws.fixture', transitive)
                    with self.assertRaisesRegex(ValueError, 'ambiguous mutation observer'):
                        run_mutations(root, [self.mutation], unexpected_check)

    def test_runner_rejects_unknown_import_syntax_before_running_bend(self):
        for declaration in ('import ./src/model.bend as Model extra', 'import ./src/model',
                            'import "./src/model.bend"', 'import package@1.0.0/main.bend'):
            with self.subTest(declaration=declaration):
                root = self.fixture()
                with (root / 'PROOF.bend').open('a') as out:
                    out.write('\n  ' + declaration + '\n')
                def unexpected_check(path):
                    self.fail('unsupported import syntax must fail before a proof check')
                with self.assertRaisesRegex(ValueError, 'unsupported Bend import'):
                    run_mutations(root, [self.mutation], unexpected_check)

    def test_runner_rejects_observer_declaration_whitespace_before_running_bend(self):
        for definition in DEFINITION_FORMS:
            with self.subTest(definition=definition):
                root = self.fixture()
                add_observer_import(root, IMPORT_FORMS[0], 'fixture', False)
                (root / 'tests/formal/other-observer.bend').write_text(
                    definition.format(name='fixture'))
                def unexpected_check(path):
                    self.fail('an ambiguous observer must fail before a proof check')
                with self.assertRaisesRegex(ValueError, 'ambiguous mutation observer'):
                    run_mutations(root, [self.mutation], unexpected_check)

    def test_runner_rejects_unknown_attribute_before_running_bend(self):
        root = self.fixture()
        add_observer_import(root, IMPORT_FORMS[0], 'fixture', False)
        (root / 'tests/formal/other-observer.bend').write_text(
            '@unknown def fixture() -> Bool:\n  True{}\n')
        def unexpected_check(path):
            self.fail('unsupported attributes must fail before a proof check')
        with self.assertRaisesRegex(ValueError, 'unsupported Bend attribute/header'):
            run_mutations(root, [self.mutation], unexpected_check)

    def test_reachability_retains_parent_imports_and_cycles(self):
        root = self.fixture()
        (root / 'PROOF.bend').write_text(' import ./src/model.bend as Model # child\n')
        (root / 'src/model.bend').write_text(' import ../PROOF.bend as Proof # cycle\n')
        self.assertEqual(proof_files(root), {root / 'PROOF.bend', root / 'src/model.bend'})

    def test_survivor_and_unrelated_failures_rejected(self):
        root = self.fixture()
        for result in [self.result(0, 'ALL PROOFS CHECK'), self.result(1, 'ALL PROOFS CHECK'),
                       self.result(0), self.result(1, ''),
                       self.result(text='SOME PROOFS FAIL\nLocation: other\n- expected : True\n- observed : False\n'),
                       self.result(text='SOME PROOFS FAIL\nLocation: Laws.fixture\nError parsing'),
                       self.result(text='SOME PROOFS FAIL\nLocation: Laws.fixture\n- expected : True\n- observed : False\nconsumed more than once'),
                       self.result(text='SOME PROOFS FAIL\nALL PROOFS CHECK\nLocation: Laws.fixture\n- expected : True\n- observed : False\n')]:
            with self.subTest(result=result), self.assertRaisesRegex(ValueError, 'expected semantic rejection'):
                require_rejection(result, self.mutation, root)

    def test_baseline_requires_success_and_verdict(self):
        for result in [self.result(), self.result(0, ''), self.result(1, 'ALL PROOFS CHECK')]:
            with self.assertRaisesRegex(ValueError, 'baseline did not pass'):
                require_baseline(result, 'fixture')

    def fixture(self):
        directory = tempfile.TemporaryDirectory(prefix='mailbend-runner-test-')
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / 'src').mkdir()
        for relative in ('LAWS.bend', 'PROOF.bend', 'src/model.bend'):
            (root / relative).write_text('safe\n')
        (root / 'PROOF.bend').write_text('def Laws.fixture() -> Bool:\n  True{}\n')
        return root

    def test_runner_isolates_mutations_and_restores_copy(self):
        root = self.fixture()
        calls = []
        def check(path):
            text = (path / 'src/model.bend').read_text()
            self.assertEqual((root / 'src/model.bend').read_text(), 'safe\n')
            calls.append((path, text))
            return self.result() if text == 'broken\n' else self.result(0, 'ALL PROOFS CHECK')
        run_mutations(root, [self.mutation], check)
        self.assertEqual([text for _, text in calls], ['safe\n', 'safe\n', 'broken\n', 'safe\n'])
        self.assertNotEqual(calls[2][0], root)
        self.assertFalse(calls[2][0].exists())

    def test_survivor_fails_without_touching_checkout(self):
        root = self.fixture()
        with self.assertRaisesRegex(ValueError, 'expected semantic rejection'):
            run_mutations(root, [self.mutation], lambda _: self.result(0, 'ALL PROOFS CHECK'))
        self.assertEqual((root / 'src/model.bend').read_text(), 'safe\n')

    def test_survivor_does_not_hide_later_controls(self):
        root = self.fixture()
        observed = []
        second = dict(self.mutation, id='second', after='second-bug')
        def check(path):
            text = (path / 'src/model.bend').read_text().strip()
            observed.append(text)
            return self.result() if text == 'second-bug' else self.result(0, 'ALL PROOFS CHECK')
        with self.assertRaisesRegex(ValueError, 'expected semantic rejection'):
            run_mutations(root, [self.mutation, second], check)
        self.assertEqual(observed, ['safe', 'safe', 'broken', 'second-bug', 'safe'])
        self.assertEqual((root / 'src/model.bend').read_text(), 'safe\n')

    def test_missing_target_cannot_pass(self):
        root = self.fixture()
        mutation = dict(self.mutation, before='absent')
        with self.assertRaisesRegex(ValueError, 'target must occur exactly once'):
            run_mutations(root, [mutation], lambda _: self.result(0, 'ALL PROOFS CHECK'))


if __name__ == '__main__':
    unittest.main()
