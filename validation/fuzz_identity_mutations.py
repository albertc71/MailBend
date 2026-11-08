"""Hosted-only validation; never modifies the candidate checkout."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HEAD = 'b9c9fa9aeee12eb048165b5f1f9eab790f28462d'
TREE = '2794accac58f217d16d5da41e9d763f5f18636b6'
CHECKER = 'scripts/check-fuzz-lock.py'
TESTS = 'tests/test-fuzz-lock.py'
PINS = {CHECKER: 'ead8b449b6a5239348a585d7bdc81ccfeb605e43cdbb25dcf6ad28c9a784e3f9',
        TESTS: '1d3a5d085caf2b7a42deb0aff5c137cdf34b67e06b56192e64ec4edeffb936ee'}
# Each mutation changes one previously reviewed behavior, not the test oracle.
MUTANTS = [
    ('checksum', 'test_changed_checksum_is_rejected',
     'if native.packages[parent].checksum != fuzz.packages[parent].checksum:',
     'if False:', 'AssertionError: 0 != 1', 'Shared native dependency identities and edges match', 1),
    ('source', 'test_redirected_source_edge_is_not_masked_by_unused_matching_package',
     'if target not in fuzz_edges:',
     'if not any(target.name == edge.name and target.version == edge.version for edge in fuzz_edges):',
     'AssertionError: 0 != 1', 'Shared native dependency identities and edges match', 1),
    ('version', 'test_redirected_version_edge_is_not_masked_by_unused_matching_package',
     'if target not in fuzz_edges:',
     'if not any(target.name == edge.name and target.source == edge.source for edge in fuzz_edges):',
     'AssertionError: 0 != 1', 'Shared native dependency identities and edges match', 1),
    ('extras', 'test_extra_fuzz_edge_can_reach_another_version_of_shared_name',
     '        for target in sorted(shipped_edges, key=str):',
     "        if shipped_edges != fuzz_edges:\n            raise ValueError('unexpected fuzz-only edge')\n        for target in sorted(shipped_edges, key=str):",
     'AssertionError: 1 != 0', 'unexpected fuzz-only edge', 1),
    ('ambiguity', 'test_ambiguous_shorthand_reference_is_rejected_on_either_side',
     '            if len(matches) != 1:', '            if not matches:',
     'AssertionError: 0 != 1', 'Shared native dependency identities and edges match', 2),
    ('eager', 'test_unresolved_reference_on_fuzz_only_parent_is_outside_guard_scope',
     'def check(native, fuzz):\n    pending = []',
     'def check(native, fuzz):\n    for extra in fuzz.packages:\n        fuzz.edges(extra)\n    pending = []',
     'AssertionError: 1 != 0', "unresolved reference 'absent-package'", 1),
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def emit(label, **values):
    print(json.dumps(dict(label=label, **values), sort_keys=True), flush=True)


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], timeout=10).decode().strip()


def run(root, label, method=None):
    argv = [sys.executable, '-B', TESTS, '-v']
    if method:
        argv.append('FuzzLockTests.' + method)
    try:
        result = subprocess.run(argv, cwd=root, capture_output=True, text=True, timeout=60)
        emit(label, argv=argv, returncode=result.returncode, stdout=result.stdout, stderr=result.stderr)
        return result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired as error:
        emit(label, infrastructure_failure='timeout', seconds=60,
             stdout=repr(error.stdout), stderr=repr(error.stderr))
        return None, ''


def healthy(root, label, method=None):
    code, output = run(root, label, method)
    expected = 'Ran 1 test in ' if method else 'Ran 26 tests in '
    return code == 0 and expected in output and '\nOK\n' in output


def main():
    source = Path(sys.argv[1]).resolve()
    if git(source, 'rev-parse', 'HEAD') != HEAD or git(source, 'rev-parse', 'HEAD^{tree}') != TREE:
        raise RuntimeError('candidate identity mismatch')
    if git(source, 'status', '--porcelain', '--untracked-files=all'):
        raise RuntimeError('candidate is not clean')
    originals = {path: (source / path).read_bytes() for path in PINS}
    if any(sha(originals[path]) != expected for path, expected in PINS.items()):
        raise RuntimeError('candidate file hash mismatch')
    python = Path(sys.executable).resolve()
    emit('identity', head=HEAD, tree=TREE, files=PINS, python=str(python),
         python_sha256=sha(python.read_bytes()), python_version=sys.version,
         runner_sha256=sha(Path(__file__).read_bytes()))
    passed = []
    with tempfile.TemporaryDirectory(prefix='fuzz-identity-', dir=os.environ['RUNNER_TEMP']) as temporary:
        workspace = Path(temporary)
        def copy(name):
            root = workspace / name
            for path, data in originals.items():
                out = root / path
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_bytes(data)
            return root
        baseline = copy('baseline')
        if not healthy(baseline, 'full-baseline'):
            raise RuntimeError('healthy baseline failed; mutations not credited')
        for name, method, before, after, assertion, diagnostic, failures in MUTANTS:
            root = copy(name)
            original = originals[CHECKER].decode()
            if original.count(before) != 1:
                raise RuntimeError('mutation match count: ' + name)
            healthy_before = healthy(root, name + '-healthy', method)
            mutated = original.replace(before, after, 1).encode()
            (root / CHECKER).write_bytes(mutated)
            emit(name + '-delta', before=before, after=after, original_sha256=sha(originals[CHECKER]),
                 mutant_sha256=sha(mutated), test_sha256=sha((root / TESTS).read_bytes()))
            code, output = run(root, name + '-mutant', method)
            killed = (code == 1 and assertion in output and diagnostic in output
                      and f'FAILED (failures={failures})' in output
                      and ('FAIL: ' + method) in output and 'Ran 1 test in ' in output
                      and 'ERROR:' not in output and 'SyntaxError' not in output
                      and 'ImportError' not in output and 'TimeoutExpired' not in output)
            (root / CHECKER).write_bytes(originals[CHECKER])
            restored = {path: sha((root / path).read_bytes()) for path in PINS}
            restored_ok = restored == PINS and healthy(root, name + '-restored', method)
            emit(name + '-outcome', healthy=healthy_before, semantic_rejection=killed,
                 restored=restored_ok, restored_hashes=restored)
            passed.append(healthy_before and killed and restored_ok)
        passed.append(healthy(baseline, 'full-restored-baseline'))
    unchanged = all((source / path).read_bytes() == data for path, data in originals.items())
    unchanged = unchanged and not git(source, 'status', '--porcelain', '--untracked-files=all')
    emit('summary', mutants=6, semantic_outcomes=passed[:6], final_baseline=passed[-1], source_unchanged=unchanged)
    return 0 if all(passed) and unchanged else 1


if __name__ == '__main__':
    sys.exit(main())
