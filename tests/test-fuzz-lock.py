#!/usr/bin/env python3
"""Exercise the offline lock guard through its command-line interface."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / 'scripts/check-fuzz-lock.py'

MANIFEST = '''\
[dependencies]
libfuzzer-sys = "0.4.13"
mailbend-net = { path = "../mailbend-net" }
mailbend-tls = { path = "../mailbend-tls" }
[workspace]
'''

DISCONNECTED = '''\
version = 4
[[package]]
name = "mailbend-net"
version = "0.1.0"
dependencies = ["net-leaf"]
[[package]]
name = "mailbend-tls"
version = "0.1.0"
dependencies = ["tls-leaf"]
[[package]]
name = "net-leaf"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "1111111111111111111111111111111111111111111111111111111111111111"
[[package]]
name = "tls-leaf"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "2222222222222222222222222222222222222222222222222222222222222222"
'''

THIRD_ROOT = '''\
[[package]]
name = "mailbend-extra"
version = "0.1.0"
dependencies = ["extra-leaf"]
[[package]]
name = "extra-leaf"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "1111111111111111111111111111111111111111111111111111111111111111"
'''

STALE_THIRD_ROOT = '''\
[[package]]
name = "mailbend-extra"
version = "0.1.0"
dependencies = ["extra-leaf"]
[[package]]
name = "extra-leaf"
version = "2.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "2222222222222222222222222222222222222222222222222222222222222222"
'''

NATIVE = '''\
version = 4
[[package]]
name = "mailbend-net"
version = "0.1.0"
dependencies = ["codec"]
[[package]]
name = "mailbend-tls"
version = "0.1.0"
dependencies = ["mailbend-net"]
[[package]]
name = "codec"
version = "1.0.1"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "1111111111111111111111111111111111111111111111111111111111111111"
'''

STALE = '''\
version = 4
[[package]]
name = "mailbend-net"
version = "0.1.0"
dependencies = ["codec"]
[[package]]
name = "mailbend-tls"
version = "0.1.0"
dependencies = ["mailbend-net"]
[[package]]
name = "codec"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "2222222222222222222222222222222222222222222222222222222222222222"
'''


class FuzzLockTests(unittest.TestCase):
    def check(self, native, fuzz, manifest=MANIFEST):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shipped = root / 'native.lock'
            harness = root / 'fuzz.lock'
            manifest_path = root / 'Cargo.toml'
            for path, content in ((shipped, native), (harness, fuzz),
                                  (manifest_path, manifest)):
                path.write_bytes(content.encode('utf-8') if isinstance(content, str) else content)
            return subprocess.run(
                [sys.executable, '-B', str(CHECKER), '--native', str(shipped),
                 '--fuzz', str(harness), '--manifest', str(manifest_path)],
                cwd=root, capture_output=True,
                text=True, timeout=5)

    def test_invalid_utf8_diagnostic_names_each_input(self):
        for name in ('manifest', 'native', 'fuzz'):
            for malformed in (b'\xff', b'\xed\xa0\x80', b'\xe2\x82'):
                with self.subTest(input=name, malformed=malformed):
                    inputs = {'native': NATIVE, 'fuzz': NATIVE, 'manifest': MANIFEST}
                    inputs[name] = inputs[name].encode('utf-8') + b'\n# fixture-only ' + malformed
                    result = self.check(**inputs)
                    path = result.args[result.args.index('--' + name) + 1]
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, '')
                    self.assertEqual(result.stderr,
                                     f'fuzz lock check failed: {path}: invalid UTF-8\n')

    def test_valid_utf8_comments_are_accepted_in_all_inputs(self):
        comment = '\n# café € 🙂\n'
        result = self.check(NATIVE + comment, NATIVE + comment, MANIFEST + comment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout,
                         'Shared native dependency identities and edges match the fuzz lock.\n')
        self.assertEqual(result.stderr, '')

    def test_matching_shared_dependencies(self):
        result = self.check(NATIVE, NATIVE)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_disconnected_roots_match(self):
        result = self.check(DISCONNECTED, DISCONNECTED)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_default_repository_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run([sys.executable, '-B', str(CHECKER)], cwd=tmp,
                                    capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_manifest_metadata_and_dependency_options_are_benign(self):
        manifest = MANIFEST.replace('path = "../mailbend-net"',
                                    'path = "../mailbend-net", default-features = false')
        manifest += '\n[workspace.metadata]\nnote = "fixture"\n'
        result = self.check(DISCONNECTED, DISCONNECTED, manifest)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_each_disconnected_root_checks_its_own_leaf(self):
        for checksum, leaf in (('1' * 64, 'net-leaf'), ('2' * 64, 'tls-leaf')):
            with self.subTest(leaf=leaf):
                changed = DISCONNECTED.replace(checksum, '3' * 64)
                result = self.check(DISCONNECTED, changed)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('checksum mismatch', result.stderr)
                self.assertIn(leaf, result.stderr)

    def test_new_root_rejected_even_when_old_roots_match(self):
        for section in ('dependencies', 'build-dependencies', 'dev-dependencies',
                        'target.\'cfg(unix)\'.dependencies',
                        'target.\'cfg(unix)\'.build-dependencies',
                        'target.\'cfg(unix)\'.dev-dependencies'):
            declaration = 'mailbend-extra = { path = "../mailbend-extra" }\n'
            manifest = (MANIFEST.replace('[dependencies]\n', '[dependencies]\n' + declaration)
                        if section == 'dependencies' else
                        MANIFEST + f'\n[{section}]\n' + declaration)
            for third in (THIRD_ROOT, STALE_THIRD_ROOT):
                with self.subTest(section=section, drift=third == STALE_THIRD_ROOT):
                    result = self.check(DISCONNECTED + THIRD_ROOT,
                                        DISCONNECTED + third, manifest)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn('unsupported fuzz root inventory', result.stderr)
                    self.assertIn('mailbend-extra', result.stderr)

    def test_removed_redirected_and_aliased_roots_are_rejected(self):
        original = 'mailbend-net = { path = "../mailbend-net" }'
        for replacement in ('', 'mailbend-net = "0.1.0"',
                            'mailbend-net = { path = "../other" }',
                            'net = { package = "mailbend-net", path = "../mailbend-net" }',
                            'mailbend-net = { package = "other", path = "../mailbend-net" }',
                            'mailbend-net = { workspace = true }'):
            with self.subTest(replacement=replacement):
                result = self.check(DISCONNECTED, DISCONNECTED,
                                    MANIFEST.replace(original, replacement))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('unsupported fuzz root inventory', result.stderr)

    def test_either_root_removed_or_moved_is_rejected_despite_stale_locks(self):
        for name in ('mailbend-net', 'mailbend-tls'):
            declaration = f'{name} = {{ path = "../{name}" }}\n'
            removed = MANIFEST.replace(declaration, '')
            for suffix in ('', '\n[build-dependencies]\n' + declaration,
                           '\n[dev-dependencies]\n' + declaration,
                           '\n[target.\'cfg(unix)\'.dependencies]\n' + declaration):
                with self.subTest(name=name, suffix=suffix):
                    result = self.check(DISCONNECTED, DISCONNECTED, removed + suffix)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn('unsupported fuzz root inventory', result.stderr)

    def test_unsupported_manifest_selection_forms_are_rejected(self):
        for extra in ('[workspace.dependencies]\nextra = { path = "../extra" }',
                      '[dependencies.extra]\nworkspace = true',
                      '[dependencies.extra]\npackage = "another"\nversion = "1"',
                      '[build_dependencies]\nextra = { path = "../extra" }',
                      '[target.\'cfg(unix)\'.dev_dependencies]\nextra = { path = "../extra" }',
                      '[patch.crates-io]\nextra = { path = "../extra" }',
                      '[replace]\n"extra:1.0.0" = { path = "../extra" }'):
            with self.subTest(extra=extra):
                result = self.check(DISCONNECTED, DISCONNECTED, MANIFEST + '\n' + extra)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('unsupported fuzz root inventory', result.stderr)
        result = self.check(DISCONNECTED, DISCONNECTED,
                            MANIFEST.replace('[workspace]', '[workspace]\nmembers = ["extra"]'))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('unsupported fuzz root inventory', result.stderr)

    def test_registry_extras_and_unrelated_native_helper_are_benign(self):
        native = DISCONNECTED + '''\
[[package]]
name = "unrelated-helper"
version = "0.1.0"
'''
        fuzz = DISCONNECTED + '''\
[[package]]
name = "fuzz-only"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "3333333333333333333333333333333333333333333333333333333333333333"
'''
        for section in ('dependencies', 'build-dependencies', 'dev-dependencies',
                        'target.\'cfg(unix)\'.dependencies'):
            extra = 'fuzz-only = { version = "1.0.0", optional = true }\n'
            manifest = (MANIFEST.replace('[dependencies]\n', '[dependencies]\n' + extra)
                        if section == 'dependencies' else MANIFEST + f'\n[{section}]\n' + extra)
            result = self.check(native, fuzz, manifest)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_malformed_manifest_tables_fail_cleanly(self):
        for manifest in ('dependencies = []', 'target = []', 'workspace = []',
                         '[target]\nunix = []', '[dependencies]\nextra = 42',
                         '[workspace]\ndependencies = []', '[workspace]\nmembers = {}',
                         '[dependencies'):
            with self.subTest(manifest=manifest):
                result = self.check(DISCONNECTED, DISCONNECTED, manifest)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('Cargo.toml', result.stderr)
                self.assertNotIn('Traceback', result.stderr)

    def test_opaque_source_with_parentheses(self):
        lock = '''\
version = 4
[[package]]
name = "mailbend-net"
version = "0.1.0"
dependencies = ["codec"]
[[package]]
name = "mailbend-tls"
version = "0.1.0"
dependencies = ["mailbend-net"]
[[package]]
name = "codec"
version = "1.0.1"
source = "git+https://example.invalid/codec(feature)#0123456789abcdef"
'''
        result = self.check(lock, lock)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_qualified_opaque_source_disambiguates_same_name_and_version(self):
        lock = '''\
version = 4
[[package]]
name = "mailbend-net"
version = "0.1.0"
dependencies = ["codec 1.0.1 (git+https://example.invalid/codec(feature)#0123456789abcdef)"]
[[package]]
name = "mailbend-tls"
version = "0.1.0"
dependencies = ["mailbend-net"]
[[package]]
name = "codec"
version = "1.0.1"
source = "git+https://example.invalid/codec(feature)#0123456789abcdef"
[[package]]
name = "codec"
version = "1.0.1"
source = "git+https://example.invalid/other#fedcba9876543210"
'''
        result = self.check(lock, lock)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_redirected_source_edge_is_not_masked_by_unused_matching_package(self):
        native = '''\
version = 4
[[package]]
name = "mailbend-net"
version = "0.1.0"
dependencies = ["codec 1.0.1 (git+https://example.invalid/codec(feature)#0123456789abcdef)"]
[[package]]
name = "mailbend-tls"
version = "0.1.0"
dependencies = ["mailbend-net"]
[[package]]
name = "codec"
version = "1.0.1"
source = "git+https://example.invalid/codec(feature)#0123456789abcdef"
[[package]]
name = "codec"
version = "1.0.1"
source = "git+https://example.invalid/other#fedcba9876543210"
'''
        fuzz = '''\
version = 4
[[package]]
name = "mailbend-net"
version = "0.1.0"
dependencies = ["codec 1.0.1 (git+https://example.invalid/other#fedcba9876543210)"]
[[package]]
name = "mailbend-tls"
version = "0.1.0"
dependencies = ["mailbend-net"]
[[package]]
name = "codec"
version = "1.0.1"
source = "git+https://example.invalid/codec(feature)#0123456789abcdef"
[[package]]
name = "codec"
version = "1.0.1"
source = "git+https://example.invalid/other#fedcba9876543210"
'''
        result = self.check(native, fuzz)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('missing shared edge', result.stderr)
        self.assertIn('codec(feature)#0123456789abcdef', result.stderr)

    def test_registry_checksum_missing_on_both_sides_is_rejected(self):
        lock = NATIVE.replace(
            'checksum = "1111111111111111111111111111111111111111111111111111111111111111"\n', '')
        result = self.check(lock, lock)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('missing registry checksum', result.stderr)
        self.assertIn('codec', result.stderr)

    def test_ambiguous_shorthand_reference_is_rejected_on_either_side(self):
        ambiguous = NATIVE + '''\
[[package]]
name = "codec"
version = "2.0.0"
source = "git+https://example.invalid/codec#fedcba9876543210"
'''
        for native, fuzz in ((ambiguous, NATIVE), (NATIVE, ambiguous)):
            with self.subTest(native_is_ambiguous=native == ambiguous):
                result = self.check(native, fuzz)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('ambiguous reference', result.stderr)
                self.assertIn('codec', result.stderr)

    def test_roots_absent_from_both_locks_cannot_pass_vacuously(self):
        lock = '''\
version = 4
[[package]]
name = "unrelated"
version = "0.1.0"
'''
        result = self.check(lock, lock)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('local root mailbend-net', result.stderr)

    def test_registry_package_cannot_replace_local_root(self):
        fuzz = NATIVE.replace('name = "mailbend-net"\nversion = "0.1.0"', '''\
name = "mailbend-net"
version = "0.1.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "3333333333333333333333333333333333333333333333333333333333333333"''')
        result = self.check(NATIVE, fuzz)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('local root mailbend-net', result.stderr)

    def test_extra_fuzz_edge_can_reach_another_version_of_shared_name(self):
        fuzz = '''\
version = 4
[[package]]
name = "mailbend-net"
version = "0.1.0"
dependencies = ["codec 1.0.1"]
[[package]]
name = "mailbend-tls"
version = "0.1.0"
dependencies = ["mailbend-net"]
[[package]]
name = "codec"
version = "1.0.1"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "1111111111111111111111111111111111111111111111111111111111111111"
dependencies = ["fuzz-helper"]
[[package]]
name = "fuzz-helper"
version = "0.1.0"
dependencies = ["codec 2.0.0"]
[[package]]
name = "codec"
version = "2.0.0"
source = "git+https://example.invalid/codec#fedcba9876543210"
'''
        result = self.check(NATIVE, fuzz)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unresolved_reference_on_fuzz_only_parent_is_outside_guard_scope(self):
        fuzz = NATIVE + '''\
[[package]]
name = "fuzz-only"
version = "0.1.0"
dependencies = ["absent-package"]
'''
        result = self.check(NATIVE, fuzz)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unresolved_extra_reference_on_shared_parent_is_rejected(self):
        fuzz = NATIVE.replace('dependencies = ["codec"]',
                              'dependencies = ["codec", "absent-package"]')
        result = self.check(NATIVE, fuzz)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('unresolved reference', result.stderr)
        self.assertIn('absent-package', result.stderr)

    def test_changed_checksum_is_rejected(self):
        fuzz = NATIVE.replace('1111111111111111111111111111111111111111111111111111111111111111',
                              '4444444444444444444444444444444444444444444444444444444444444444')
        result = self.check(NATIVE, fuzz)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('checksum mismatch', result.stderr)
        self.assertIn('codec', result.stderr)

    def test_changed_source_identity_is_rejected(self):
        fuzz = NATIVE.replace('registry+https://github.com/rust-lang/crates.io-index',
                              'registry+https://example.invalid/other-index')
        result = self.check(NATIVE, fuzz)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('missing shared edge', result.stderr)
        self.assertIn('github.com/rust-lang/crates.io-index', result.stderr)

    def test_missing_shared_package_is_rejected(self):
        fuzz = NATIVE.split('[[package]]\nname = "codec"')[0]
        result = self.check(NATIVE, fuzz)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('unresolved reference', result.stderr)
        self.assertIn('codec', result.stderr)

    def test_redirected_version_edge_is_not_masked_by_unused_matching_package(self):
        native = NATIVE.replace('dependencies = ["codec"]', 'dependencies = ["codec 1.0.1"]')
        native += '''\
[[package]]
name = "codec"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "2222222222222222222222222222222222222222222222222222222222222222"
'''
        fuzz = native.replace('dependencies = ["codec 1.0.1"]',
                              'dependencies = ["codec 1.0.0"]')
        result = self.check(native, fuzz)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('missing shared edge', result.stderr)
        self.assertIn('codec 1.0.1', result.stderr)

    def test_duplicate_exact_identity_is_rejected_on_either_side(self):
        duplicate = NATIVE + '''\
[[package]]
name = "codec"
version = "1.0.1"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "1111111111111111111111111111111111111111111111111111111111111111"
'''
        for native, fuzz in ((duplicate, NATIVE), (NATIVE, duplicate)):
            with self.subTest(native_is_duplicate=native == duplicate):
                result = self.check(native, fuzz)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('duplicate package', result.stderr)
                self.assertIn('codec', result.stderr)

    def test_mismatched_local_root_version_is_rejected(self):
        fuzz = NATIVE.replace('name = "mailbend-net"\nversion = "0.1.0"',
                              'name = "mailbend-net"\nversion = "0.2.0"')
        result = self.check(NATIVE, fuzz)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('mismatched local root', result.stderr)
        self.assertIn('mailbend-net', result.stderr)

    def test_missing_second_root_is_rejected_on_either_or_both_sides(self):
        missing = NATIVE.replace('''\
[[package]]
name = "mailbend-tls"
version = "0.1.0"
dependencies = ["mailbend-net"]
''', '')
        for native, fuzz in ((missing, NATIVE), (NATIVE, missing), (missing, missing)):
            with self.subTest(native_missing=native == missing, fuzz_missing=fuzz == missing):
                result = self.check(native, fuzz)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('local root mailbend-tls', result.stderr)

    def test_multiple_local_root_versions_are_rejected_on_either_side(self):
        multiple = NATIVE + '''\
[[package]]
name = "mailbend-net"
version = "0.2.0"
'''
        for native, fuzz in ((multiple, NATIVE), (NATIVE, multiple)):
            with self.subTest(native_multiple=native == multiple):
                result = self.check(native, fuzz)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('exactly one local root mailbend-net', result.stderr)

    def test_malformed_extra_reference_is_checked_only_on_shared_parents(self):
        orphan = NATIVE + '''\
[[package]]
name = "fuzz-only"
version = "0.1.0"
dependencies = ["codec 1.0.1 (unterminated"]
'''
        result = self.check(NATIVE, orphan)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        shared = NATIVE.replace('dependencies = ["codec"]',
                                'dependencies = ["codec", "codec 1.0.1 (unterminated"]')
        result = self.check(NATIVE, shared)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('malformed reference', result.stderr)
        self.assertIn('unterminated', result.stderr)

    def test_equivalent_ordering_and_unambiguous_notation_are_accepted(self):
        fuzz = '''\
version = 3
[[package]]
name = "codec"
version = "1.0.1"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "1111111111111111111111111111111111111111111111111111111111111111"
[[package]]
name = "mailbend-tls"
version = "0.1.0"
dependencies = ["mailbend-net 0.1.0"]
[[package]]
name = "mailbend-net"
version = "0.1.0"
dependencies = ["codec 1.0.1 (registry+https://github.com/rust-lang/crates.io-index)"]
'''
        result = self.check(NATIVE, fuzz)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unknown_lock_format_is_rejected_on_either_side(self):
        unknown = NATIVE.replace('version = 4\n', 'version = 99\n', 1)
        for native, fuzz in ((unknown, NATIVE), (NATIVE, unknown)):
            with self.subTest(native_unknown=native == unknown):
                result = self.check(native, fuzz)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('unsupported lock format version', result.stderr)

    def test_shared_cycle_and_shared_descendant_terminate(self):
        lock = '''\
version = 4
[[package]]
name = "mailbend-net"
version = "0.1.0"
dependencies = ["mailbend-tls", "leaf"]
[[package]]
name = "mailbend-tls"
version = "0.1.0"
dependencies = ["mailbend-net", "leaf"]
[[package]]
name = "leaf"
version = "0.1.0"
'''
        reordered = lock.replace('["mailbend-tls", "leaf"]', '["leaf", "mailbend-tls"]')
        reordered = reordered.replace('["mailbend-net", "leaf"]', '["leaf", "mailbend-net"]')
        result = self.check(lock, reordered)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_malformed_native_diagnostic_names_input(self):
        result = self.check('version = [\n', NATIVE)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('native.lock', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_malformed_fuzz_diagnostic_names_input(self):
        result = self.check(NATIVE, 'version = [\n')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('fuzz.lock', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_reachable_version_drift(self):
        result = self.check(NATIVE, STALE)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('codec', result.stderr)


if __name__ == '__main__':
    unittest.main()
