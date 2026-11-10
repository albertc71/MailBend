"""Observe the same two reason deletions before and after the added laws."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

BASE = '1633acf1e5eb5e3829ca0b43596d2a8319f83920'
CANDIDATE = 'b5a0752872149b8f65e4affe58556e7cba32eb5f'
MUTANTS = (
    ('search', 'Bool.pick(String, I.refused(lines, 2), "search_refused", "")',
     'Bool.pick(String, I.refused(lines, 2), "", "")',
     'original_mark_search_refusal_fields_example'),
    ('store', 'Bool.pick(String, I.refused(lines, 3), "store_refused", "")',
     'Bool.pick(String, I.refused(lines, 3), "", "")',
     'original_mark_store_refusal_fields_example'),
)


def fingerprints(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for directory in ('src', 'tests/formal')
            for p in sorted((root / directory).rglob('*')) if p.is_file()}


def check(root):
    result = subprocess.run(['bend', 'tests/formal/tool-laws.bend', '--check-only'],
                            cwd=root, capture_output=True, text=True, timeout=300,
                            env=dict(os.environ, BEND_NO_TELEMETRY='1'))
    return result.returncode, result.stdout + result.stderr


def require_pass(root, label):
    code, output = check(root)
    assert code == 0 and 'ALL PROOFS CHECK' in output, (label, code, output)
    print(f'PASS {label}', flush=True)


def observe(source, label, expected_sha, reject):
    actual_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    assert actual_sha == expected_sha, (label, actual_sha, expected_sha)
    print(f'SOURCE {label} {actual_sha}', flush=True)
    before_files = fingerprints(source)
    original = (source / 'src/tools.bend').read_text()
    with tempfile.TemporaryDirectory(prefix=f'mailbend-refusal-{label}-') as directory:
        root = Path(directory)
        shutil.copytree(source / 'src', root / 'src')
        shutil.copytree(source / 'tests/formal', root / 'tests/formal',
                        ignore=shutil.ignore_patterns('__pycache__'))
        require_pass(root, f'{label} unmutated laws')
        target = root / 'src/tools.bend'
        for name, before, after, law in MUTANTS:
            assert original.count(before) == 1, (name, 'target is not unique')
            target.write_text(original.replace(before, after))
            code, output = check(root)
            print(f'DIAGNOSTIC_BEGIN {label} {name} exit={code}', flush=True)
            print(output, flush=True)
            print(f'DIAGNOSTIC_END {label} {name}', flush=True)
            if reject:
                location = re.search(r'^Location: (\S+)', output, re.MULTILINE)
                assert (code != 0 and 'SOME PROOFS FAIL' in output
                        and location is not None and location.group(1) == law
                        and re.search(r'^- expected\s*:', output, re.MULTILINE)
                        and re.search(r'^- observed\s*:', output, re.MULTILINE)), (name, law, code, output)
                print(f'PASS rejected {name} reason deletion at {law}', flush=True)
            else:
                assert code == 0 and 'ALL PROOFS CHECK' in output, (name, code, output)
                print(f'PASS reproduced {name} reason-deletion survivor', flush=True)
            target.write_text(original)
        require_pass(root, f'{label} restored laws')
    assert fingerprints(source) == before_files, (label, 'source files changed')
    print(f'PASS {label} source files unchanged', flush=True)


def main():
    baseline, candidate = (Path(p).resolve() for p in sys.argv[1:])
    assert (baseline / 'src/tools.bend').read_bytes() == (candidate / 'src/tools.bend').read_bytes()
    for path, expected in (
        ('tests/formal/tool-laws.bend', '6555d2b6dc8cd922f37cec09459733a3fbb72136a40268e40f25f7cdb580599f'),
        ('tests/formal/check-reply-marking.py', '5a8208e1228e219345b5362702b97ddd3be970b4a0e32397503754a814dab2e9'),
    ):
        assert hashlib.sha256((candidate / path).read_bytes()).hexdigest() == expected, path
    observe(baseline, 'baseline', BASE, False)
    observe(candidate, 'candidate', CANDIDATE, True)
    print('PASS both old-law survivors and both new-law rejections observed', flush=True)


if __name__ == '__main__':
    main()
