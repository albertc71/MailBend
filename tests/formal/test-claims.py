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
from law_catalogue import catalogue, generated, load_json
from mutation_runner import require_baseline, require_rejection, run_mutations

SPEC = importlib.util.spec_from_file_location("claim_checks", ROOT / "tools/check-claims.py")
CHECKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKS)


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
        path = self.root / 'tests/formal/other-observer.bend'
        path.write_text('def plan_quota_writes_nothing() -> Bool:\n  True{}\n')
        with (self.root / 'PROOF.bend').open('a') as out:
            out.write('\nimport ./tests/formal/other-observer.bend as Other\n')
        self.rejected("ambiguous mutation observer")

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
        root = self.fixture()
        (root / 'src/other.bend').write_text('def fixture() -> Bool:\n  True{}\n')
        with (root / 'PROOF.bend').open('a') as out:
            out.write('\nimport ./src/other.bend as Other\n')
        with self.assertRaisesRegex(ValueError, 'ambiguous mutation observer'):
            require_rejection(self.result(), self.mutation, root)

    def test_runner_rejects_ambiguous_observer_before_running_bend(self):
        root = self.fixture()
        (root / 'src/other.bend').write_text('def Laws.fixture() -> Bool:\n  True{}\n')
        with (root / 'PROOF.bend').open('a') as out:
            out.write('\nimport ./src/other.bend as Other\n')
        def unexpected_check(path):
            self.fail('an ambiguous observer must fail before a proof check')
        with self.assertRaisesRegex(ValueError, 'ambiguous mutation observer'):
            run_mutations(root, [self.mutation], unexpected_check)

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
