#!/usr/bin/env python3
"""One-shot hosted evidence for the brief duplicate-UID fixture, never real mail."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

WIRE_CHECK = 'brief continuation: duplicate fixture emits duplicate UIDs on both pages'
GROUP_CHECK = 'brief continuation: duplicate SEARCH group counts match returned messages'
BEFORE = 'matched = [uid for uid in matched for _ in range(2)]'
AFTER = 'matched = list(matched)'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def phase(root, report):
    sys.path.insert(0, str(root / 'tests'))
    harness = load('brief_control_e2e', root / 'tests/test-e2e.py')
    cases = load('brief_control_cases', root / 'tests/brief-continuation-cases.py')
    original_server = harness.Server
    normal_log_checks = []

    class ObservedServer(original_server):
        def __init__(self, *args, **kwargs):
            extra = kwargs.get('extra', ())
            self.duplicate_mode = '--search-response' in extra and extra[extra.index('--search-response') + 1] == 'duplicate-uids'
            super().__init__(*args, **kwargs)

        def stop(self):
            # Check before later servers reuse the fixture log pathname.
            try:
                if not self.duplicate_mode:
                    normal_log_checks.append(not any(record['proto'] == 'imap-search-response'
                                                     for record in self.log_records()))
            finally:
                super().stop()

    harness.Server = ObservedServer
    with tempfile.TemporaryDirectory(prefix='brief-duplicate-control-') as work:
        subprocess.run(['sh', str(root / 'tests/gen-test-certs.sh'), str(Path(work) / 'certs')],
                       check=True, capture_output=True, timeout=30)
        cases.run(harness, work)
    failed = [name for name, ok in harness.results if not ok]
    names = [name for name, _ in harness.results]
    assert names.count(WIRE_CHECK) == 1, 'wire observer did not run exactly once'
    assert names.count(GROUP_CHECK) == 2, 'both page group observers must run'
    assert normal_log_checks and all(normal_log_checks), 'opt-in logging changed another mode'
    assert not any(harness.PASSWORD in output for output in harness.outputs), 'synthetic password in tool output'
    report.write_text(json.dumps({'checks': len(names), 'failed': failed,
                                  'normal_log_checks': len(normal_log_checks)}), encoding='utf-8')
    return bool(failed)


def run_phase(root, name, report):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('MAILBEND_', 'TYPESAFE_'))}
    process = subprocess.Popen([sys.executable, '-B', __file__, '--root', str(root),
                                '--phase', '--report', str(report)],
                               env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    completed = False
    try:
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            # Observe exit without reaping: keep the group identity reserved.
            if os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT):
                completed = True
                break
            time.sleep(0.05)
    finally:
        # Clean descendants on success, exception and timeout alike. Never use
        # poll/wait/communicate before the final group signal, even after exit.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        time.sleep(0.2)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
    if not completed:
        raise AssertionError(f'{name}: timed out, not mutation evidence')
    if not report.is_file():
        raise AssertionError(f'{name}: no complete phase report (exit {process.returncode})')
    result = json.loads(report.read_text(encoding='utf-8'))
    expected_failures = [WIRE_CHECK] if name == 'without-duplicate-emission' else []
    assert result['failed'] == expected_failures, (name, result)
    assert process.returncode == bool(expected_failures), (name, process.returncode)
    print(json.dumps({'phase': name, 'exit': process.returncode, **result}), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    if args.phase:
        assert args.report is not None
        return phase(root, args.report)
    target = root / 'tests/fake_mail_server.py'
    original = target.read_bytes()
    source = original.decode('utf-8')
    assert source.count(BEFORE) == 1, 'mutation anchor must be unique'
    assert 'self.logger.log(\'imap-search-response\', text)' in source
    print('candidate fixture sha256=' + hashlib.sha256(original).hexdigest(), flush=True)
    with tempfile.TemporaryDirectory(prefix='brief-control-reports-') as reports:
        reports = Path(reports)
        baseline = run_phase(root, 'baseline', reports / 'baseline.json')
        try:
            # Only emission changes: keep the application, test, and wire observer unchanged.
            target.write_text(source.replace(BEFORE, AFTER), encoding='utf-8')
            mutant = run_phase(root, 'without-duplicate-emission', reports / 'mutant.json')
            assert mutant['checks'] == baseline['checks'], 'mutant skipped checks'
        finally:
            target.write_bytes(original)
        assert target.read_bytes() == original, 'fixture was not restored'
        restored = run_phase(root, 'restored', reports / 'restored.json')
        assert restored == baseline, 'restoration did not reproduce baseline'
    print('PASS: disabling duplicate emission fails only the independent wire oracle; restoration passes.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
