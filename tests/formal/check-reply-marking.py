#!/usr/bin/env python3
"""Require production transition mutants to fail the named reply-marking law."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MUTATIONS = (
    ("marking defaults on", 'Policy.bool_arg(args, "mark_answered", False{})',
     'Policy.bool_arg(args, "mark_answered", True{})', 'original_mark_defaults_off'),
    ("drafts may mark", 'Bool.not(Policy.bool_arg(args, "as_draft", False{})) && Bool.not(dry_arg(args))',
     'True{} && Bool.not(dry_arg(args))', 'original_mark_drafts_skip'),
    ("dry runs may mark", '&& Bool.not(dry_arg(args)),\n    Some{Original',
     ',\n    Some{Original', 'original_mark_dry_runs_skip'),
    ("forwards may mark", 'reply && Policy.bool_arg(args, "mark_answered", False{})',
     'True{} && Policy.bool_arg(args, "mark_answered", False{})', 'original_mark_forwards_skip'),
    ("all successful outputs mark", 'String.eq(Policy.str_arg(j, "smtp_outcome", ""), "accepted") &&',
     'True{} &&', 'original_mark_unaccepted_skips'),
    ("accepted replies never mark", 'String.eq(Policy.str_arg(j, "smtp_outcome", ""), "accepted") &&',
     'False{} &&', 'original_mark_accepted_runs'),
)


def check(root):
    return subprocess.run(['bend', 'tests/formal/tool-laws.bend', '--check-only'],
                          cwd=root, capture_output=True, text=True, timeout=300,
                          env=dict(os.environ, BEND_NO_TELEMETRY='1'))


def passing(root, label):
    result = check(root)
    assert result.returncode == 0 and 'ALL PROOFS CHECK' in result.stdout, (label, result.stdout, result.stderr)
    print(f'PASS {label}', flush=True)


def main():
    original = (ROOT / 'src/tools.bend').read_text()
    passing(ROOT, 'checkout reply-marking laws')
    with tempfile.TemporaryDirectory(prefix='mailbend-reply-marking-') as directory:
        root = Path(directory)
        shutil.copytree(ROOT / 'src', root / 'src')
        shutil.copytree(ROOT / 'tests/formal', root / 'tests/formal',
                        ignore=shutil.ignore_patterns('__pycache__'))
        passing(root, 'copied reply-marking laws')
        target = root / 'src/tools.bend'
        for label, before, after, law in MUTATIONS:
            assert original.count(before) == 1, (label, 'target is not unique')
            target.write_text(original.replace(before, after))
            result = check(root)
            output = result.stdout + result.stderr
            location = re.search(r'^Location: (\S+)', output, re.MULTILINE)
            assert (result.returncode != 0 and 'SOME PROOFS FAIL' in output
                    and location is not None and location.group(1) == law
                    and re.search(r'^- expected\s*:', output, re.MULTILINE)
                    and re.search(r'^- observed\s*:', output, re.MULTILINE)), (label, law, output)
            print(f'PASS rejected {label}: {law}', flush=True)
            target.write_text(original)
        passing(root, 'restored reply-marking laws')
    assert (ROOT / 'src/tools.bend').read_text() == original, 'checkout changed'
    print('PASS checkout unchanged', flush=True)


if __name__ == '__main__':
    main()
