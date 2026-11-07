#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

GENERATOR = Path(__file__).resolve().parents[1] / 'tools/gen-llms.py'
EXPECTED = """# MailBend documentation

Source index for MailBend, a Linux IMAP/SMTP connector for AI agents.

## Reference documentation

- [MailBend](README.md)
- [Start here](README.md#start-here)
- [CLI contract](docs/CLI.md)
- [Frameworks](docs/FRAMEWORKS.md)
- [Recipes](docs/RECIPES.md)

## Agent skill

- [MailBend skill](skills/mailbend/SKILL.md)

## Design proposals and history

These documents describe proposals and historical designs, not implementation guarantees.

- [Future design](docs/plans/future.md)
"""


class IndexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        for path, content in {
            'README.md': '# MailBend\n\n## Start here\n',
            'docs/CLI.md': '# CLI contract\n',
            'docs/FRAMEWORKS.md': '# Frameworks\n',
            'docs/RECIPES.md': '# Recipes\n',
            'skills/mailbend/SKILL.md': '---\nname: mailbend\n---\n# MailBend skill\n',
            'docs/plans/future.md': '# Future design\n',
            '.agents/skills/internal/SKILL.md': '# Internal\n',
        }.items():
            self.write(path, content)

    def write(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding='utf-8')

    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(GENERATOR), '--root', str(self.root), *args],
                              cwd=self.temp.name, capture_output=True, text=True)

    def generate(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        return (self.root / 'llms.txt').read_text(encoding='utf-8')

    def test_complete_literal_index_and_repeat_from_other_cwd(self):
        self.assertEqual(self.generate(), EXPECTED)
        self.assertEqual(self.generate(), EXPECTED)

    def test_check_missing_stale_and_current_without_writes(self):
        target = self.root / 'llms.txt'
        result = self.run_cli('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('llms.txt', result.stderr)
        self.assertIn('missing', result.stderr)
        self.assertFalse(target.exists())
        self.write('llms.txt', 'old index\n')
        result = self.run_cli('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('stale', result.stderr)
        self.assertEqual(target.read_bytes(), b'old index\n')
        self.generate()
        before = target.stat().st_mtime_ns
        result = self.run_cli('--check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.stat().st_mtime_ns, before)
        self.assertEqual(target.read_text(), EXPECTED)

    def test_missing_mandatory_pages_preserve_existing_index(self):
        for path in ('README.md', 'docs/CLI.md', 'docs/RECIPES.md',
                     'docs/FRAMEWORKS.md', 'skills/mailbend/SKILL.md'):
            with self.subTest(path=path):
                source = self.root / path
                original = source.read_bytes()
                source.unlink()
                self.write('llms.txt', 'keep me\n')
                for args in ((), ('--check',)):
                    result = self.run_cli(*args)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(path, result.stderr)
                    self.assertEqual((self.root / 'llms.txt').read_bytes(), b'keep me\n')
                source.write_bytes(original)

    def test_readme_heading_changes_duplicates_and_fences(self):
        self.generate()
        self.write('README.md', '# MailBend\n## Install (Linux)\n### Install (Linux)\n'
                   '## Install (Linux)\n## Install Linux-1\n## Install (Linux)\n'
                   '```md\n## Fake backticks\n```\n'
                   '~~~\n## Fake tilde\n~~~\n## Finish ###\n')
        self.assertNotEqual(self.run_cli('--check').returncode, 0)
        output = self.generate()
        self.assertIn('- [Install (Linux)](README.md#install-linux)\n', output)
        self.assertIn('- [Install (Linux)](README.md#install-linux-2)\n', output)
        self.assertIn('- [Install Linux-1](README.md#install-linux-1-1)\n', output)
        self.assertIn('- [Install (Linux)](README.md#install-linux-3)\n', output)
        self.assertIn('- [Finish](README.md#finish)\n', output)
        self.assertNotIn('Fake', output)
        self.assertNotIn('Start here', output)

    def test_malformed_input_preserves_previous_output(self):
        for content in (b'no title\n', b'## Not an H1\n', b'# \n', b'# Title\n```\n', b'\xff'):
            with self.subTest(content=content):
                (self.root / 'docs/CLI.md').write_bytes(content)
                self.write('llms.txt', 'keep me\n')
                for args in ((), ('--check',)):
                    result = self.run_cli(*args)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('docs/CLI.md', result.stderr)
                    self.assertNotIn('Traceback', result.stderr)
                    self.assertEqual((self.root / 'llms.txt').read_bytes(), b'keep me\n')

    def test_nested_discovery_escaping_rename_and_removal(self):
        self.generate()
        self.write('docs/nested/A [guide](v1).md', '# A [guide] *now*\n')
        self.write('skills/mailbend/references/z.md', '# Extra skill page\n')
        self.assertNotEqual(self.run_cli('--check').returncode, 0)
        output = self.generate()
        self.assertIn(r'- [A \[guide\] \*now\*](docs/nested/A%20%5Bguide%5D%28v1%29.md)', output)
        self.assertIn('- [Extra skill page](skills/mailbend/references/z.md)', output)
        (self.root / 'docs/nested/A [guide](v1).md').rename(self.root / 'docs/nested/B.md')
        self.assertNotEqual(self.run_cli('--check').returncode, 0)
        output = self.generate()
        self.assertIn('(docs/nested/B.md)', output)
        self.assertNotIn('A%20', output)
        (self.root / 'docs/nested/B.md').unlink()
        self.assertNotEqual(self.run_cli('--check').returncode, 0)
        self.assertNotIn('(docs/nested/B.md)', self.generate())

    def test_filename_fragment_characters_are_encoded(self):
        self.write('docs/hash#part?.md', '# Hash guide\n')
        self.assertIn('- [Hash guide](docs/hash%23part%3F.md)', self.generate())

    def test_check_rejects_byte_only_drift(self):
        self.generate()
        target = self.root / 'llms.txt'
        changed = target.read_bytes().replace(b'\n', b'\r\n')
        target.write_bytes(changed)
        result = self.run_cli('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('stale', result.stderr)
        self.assertEqual(target.read_bytes(), changed)

    def test_title_change_and_sorted_paths_ignore_creation_order(self):
        self.generate()
        self.write('docs/z-last.md', '# Last page\n')
        self.write('docs/a-first.md', '# First page\n')
        self.write('docs/CLI.md', '# Renamed CLI title\n')
        self.assertNotEqual(self.run_cli('--check').returncode, 0)
        output = self.generate()
        self.assertIn('- [Renamed CLI title](docs/CLI.md)', output)
        self.assertNotIn('[CLI contract]', output)
        self.assertIn('- [First page](docs/a-first.md)\n- [Last page](docs/z-last.md)', output)

    def test_long_fences_ignore_short_or_mismatched_closers(self):
        self.write('README.md', '# MailBend\n   ````markdown\n```\n## Fake short\n'
                   '~~~~\n## Fake mismatch\n   `````\n   ## Real section ###\n')
        output = self.generate()
        self.assertIn('- [Real section](README.md#real-section)', output)
        self.assertNotIn('Fake', output)

    def test_unsupported_readme_markup_preserves_existing_index(self):
        for title in ('[Install](docs/CLI.md)', 'Install &amp; use', '<em>Install</em>',
                      '*Install*', '_Install_', '`install`', r'Install \*now\*',
                      '~~Install~~'):
            for level in ('#', '##', '###', '####', '#####', '######'):
                with self.subTest(title=title, level=level):
                    self.write('README.md', '# MailBend\n' + level + ' ' + title + '\n')
                    self.write('llms.txt', 'keep me\n')
                    for args in ((), ('--check',)):
                        result = self.run_cli(*args)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn('README.md', result.stderr)
                        self.assertIn('plain-text', result.stderr)
                        self.assertNotIn('Traceback', result.stderr)
                        self.assertEqual((self.root / 'llms.txt').read_bytes(), b'keep me\n')
        self.write('README.md', '# MailBend\n## Install (Linux) / CLI!\n')
        self.write('docs/CLI.md', '# [CLI](guide) &amp; <em>reference</em>\n')
        output = self.generate()
        self.assertIn('(README.md#install-linux--cli)', output)
        self.assertIn(r'[\[CLI\](guide) &amp; \<em\>reference\</em\>](docs/CLI.md)', output)

    def test_unsupported_readme_blocks_and_unicode_preserve_output(self):
        for body in ('<!--\n## Hidden\n-->\n', '<div>\n## Hidden\n</div>\n',
                     '<script>\n## Hidden\n</script>\n',
                     '<div\tclass="example">\n## Hidden\n</div>\n', '## Café\n'):
            with self.subTest(body=body):
                self.write('README.md', '# MailBend\n' + body)
                self.write('llms.txt', 'keep me\n')
                for args in ((), ('--check',)):
                    result = self.run_cli(*args)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('README.md', result.stderr)
                    self.assertEqual((self.root / 'llms.txt').read_bytes(), b'keep me\n')
        self.write('README.md', '# MailBend\nText. <!-- claim:first --> <!-- claim:second -->\n'
                   '## Visible\n```html\n<div>\n## Hidden\n</div>\n```\n')
        output = self.generate()
        self.assertIn('[Visible](README.md#visible)', output)
        self.assertNotIn('Hidden', output)

    def test_setext_underlines_preserve_index_bytes_and_mtime(self):
        for underline in ('-------', '=======', '  -  ', '   ='):
            with self.subTest(underline=underline):
                self.write('README.md', '# MailBend\nInstall\n' + underline + '\n## Install\n')
                self.write('llms.txt', 'keep me\n')
                target = self.root / 'llms.txt'
                before = target.stat().st_mtime_ns
                for args in ((), ('--check',)):
                    result = self.run_cli(*args)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('README.md', result.stderr)
                    self.assertIn('Setext', result.stderr)
                    self.assertEqual(target.read_bytes(), b'keep me\n')
                    self.assertEqual(target.stat().st_mtime_ns, before)
        self.write('README.md', '# MailBend\n```markdown\nInstall\n-------\n'
                   'Heading\n=======\n```\n## Install\n')
        self.assertIn('[Install](README.md#install)', self.generate())
        self.assertEqual(self.run_cli('--check').returncode, 0)

    def test_hash_only_titles_are_empty_but_literal_hash_words_survive(self):
        for path, content in (('docs/CLI.md', '# #\n'), ('docs/CLI.md', '# ###\n'),
                              ('README.md', '# MailBend\n## ###\n')):
            with self.subTest(path=path, content=content):
                original = (self.root / path).read_bytes()
                self.write(path, content)
                self.write('llms.txt', 'keep me\n')
                target = self.root / 'llms.txt'
                before = target.stat().st_mtime_ns
                for args in ((), ('--check',)):
                    result = self.run_cli(*args)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(path, result.stderr)
                    self.assertEqual(target.read_bytes(), b'keep me\n')
                    self.assertEqual(target.stat().st_mtime_ns, before)
                (self.root / path).write_bytes(original)
        self.write('docs/CLI.md', '# #topic\n')
        self.write('README.md', '# MailBend\n## Heading ###\n')
        output = self.generate()
        self.assertIn('- [#topic](docs/CLI.md)', output)
        self.assertIn('- [Heading](README.md#heading)', output)
        self.assertEqual(self.run_cli('--check').returncode, 0)


if __name__ == '__main__':
    unittest.main()
