#!/usr/bin/env python3
"""Generate the offline, repository-relative MailBend documentation index."""

import argparse
from pathlib import Path
import re
import sys
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]


def headings(path, readme=False):
    result = []
    fence = None
    try:
        text = path.read_text(encoding='utf-8')
    except UnicodeError as error:
        raise ValueError(f'{path}: expected UTF-8 Markdown') from error
    for line in text.splitlines():
        if fence:
            if re.fullmatch(r' {0,3}' + re.escape(fence[0]) +
                            '{' + str(len(fence)) + r',}[ \t]*', line):
                fence = None
            continue
        opening = re.match(r' {0,3}(`{3,}|~{3,})(.*)$', line)
        if opening and not (opening[1][0] == '`' and '`' in opening[2]):
            fence = opening[1]
            continue
        if readme:
            if re.fullmatch(r' {0,3}(?:-+|=+)[ \t]*', line):
                raise ValueError('README.md: Setext underline-shaped lines are unsupported')
            without_comments = re.sub(r'<!--.*?-->', '', line)
            if ('<!--' in without_comments or
                    re.match(r' {0,3}<(?:[!/?]|[A-Za-z][A-Za-z0-9-]*(?:[ \t/>]|$))',
                             without_comments)):
                raise ValueError('README.md: HTML blocks and multiline comments are unsupported')
        match = re.fullmatch(r' {0,3}(#{1,6})[ \t]+(.+)', line)
        if match:
            title = re.sub(r'(?:^|[ \t]+)#+[ \t]*$', '', match[2]).strip()
            result.append((len(match[1]), title))
    if fence:
        raise ValueError(f'{path}: unclosed fenced code block')
    if not result or result[0][0] != 1 or not result[0][1]:
        raise ValueError(f'{path}: expected a nonempty ATX H1 title')
    if any(not title for _, title in result):
        raise ValueError(f'{path}: empty heading')
    return result


def sections(headings):
    used = set()
    result = []
    for level, title in headings:
        if (not title.isascii() or re.search(r'[\[\]<>*_`\\]|~~', title) or
                re.search(r'&(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#[xX][0-9A-Fa-f]+);', title)):
            raise ValueError('README.md: anchors require plain-text headings; '
                             'non-ASCII text, inline markup, entities and escapes are unsupported')
        base = ''.join(c for c in title.lower() if c.isalnum() or c in '_- ').replace(' ', '-')
        anchor = base
        suffix = 0
        while anchor in used:
            suffix += 1
            anchor = f'{base}-{suffix}'
        used.add(anchor)
        if level == 2:
            result.append((title, 'README.md', anchor))
    return result


def index(root):
    for required in ('README.md', 'docs/CLI.md', 'docs/RECIPES.md',
                     'docs/FRAMEWORKS.md', 'skills/mailbend/SKILL.md'):
        if not (root / required).is_file():
            raise ValueError(f'Missing required page: {required}')
    readme = headings(root / 'README.md', readme=True)
    reference = [(readme[0][1], 'README.md', None)]
    reference.extend(sections(readme))
    groups = {'Reference documentation': reference, 'Agent skill': [],
              'Design proposals and history': []}
    for folder in ('docs', 'skills/mailbend'):
        for path in sorted((root / folder).rglob('*.md')):
            relative = path.relative_to(root).as_posix()
            group = ('Agent skill' if folder == 'skills/mailbend' else
                     'Design proposals and history' if relative.startswith('docs/plans/') else
                     'Reference documentation')
            groups[group].append((headings(path)[0][1], relative, None))
    lines = ['# MailBend documentation', '',
             'Source index for MailBend, a Linux IMAP/SMTP connector for AI agents.']
    for group, entries in groups.items():
        lines += ['', '## ' + group, '']
        if group == 'Design proposals and history':
            lines += ['These documents describe proposals and historical designs, not implementation guarantees.', '']
        for title, path, anchor in entries:
            label = re.sub(r'([\\`*{}\[\]<>_!])', r'\\\1', title)
            target = quote(path, safe='/')
            if anchor is not None:
                target += '#' + quote(anchor, safe='')
            lines.append(f'- [{label}]({target})')
    return ('\n'.join(lines) + '\n').encode('utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        content = index(args.root)
        target = args.root / 'llms.txt'
        if args.check:
            if not target.exists():
                raise ValueError('llms.txt is missing; run python3 tools/gen-llms.py')
            if target.read_bytes() != content:
                raise ValueError('llms.txt is stale; run python3 tools/gen-llms.py')
        else:
            target.write_bytes(content)
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
