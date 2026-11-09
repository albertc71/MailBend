#!/usr/bin/env python3
"""Hosted-only red/green controls for the terminal regression test."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = '34570d036487d7e66ead897509fdf4dd3579f1c0'
METHOD = 'NativeTerminalTests.test_rejects_terminal_without_acquiring_it'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def replace_once(source, old, new):
    require(source.count(old) == 1, f'expected one mutation anchor: {old!r}')
    return source.replace(old, new)


def run_case(label, test_source, checker_source, optimize, expected_failure, called,
             method=METHOD):
    with tempfile.TemporaryDirectory(prefix='terminal-optimization-') as temporary:
        root = Path(temporary)
        (root / 'scripts').mkdir()
        (root / 'tests').mkdir()
        test = root / 'tests/test-native-hardening.py'
        test.write_text(test_source)
        (root / 'scripts/check-native-hardening.py').write_text(checker_source)
        marker = root / 'checker-called'
        result = subprocess.run(
            [sys.executable, str(test), method, '-v'],
            env={**os.environ, 'PYTHONOPTIMIZE': str(optimize),
                 'TERMINAL_CHECKER_MARKER': str(marker)},
            capture_output=True, text=True, timeout=20)
        require('Ran 1 test in ' in result.stderr, f'{label}: missing test execution record')
        require('ERROR:' not in result.stderr, f'{label}: infrastructure error\n{result.stderr}')
        require(result.stdout == '', f'{label}: unexpected outer stdout {result.stdout!r}')
        if expected_failure is None:
            require(result.returncode == 0 and result.stderr.endswith('\nOK\n'),
                    f'{label}: expected success\n{result.stderr}')
        else:
            require(result.returncode == 1 and 'FAILED (failures=1)' in result.stderr,
                    f'{label}: expected exactly one failure\n{result.stderr}')
            require(expected_failure in result.stderr,
                    f'{label}: wrong failure reason\n{result.stderr}')
        require(marker.exists() == called, f'{label}: checker invocation mismatch')
        if called:
            require(marker.read_text() == str(optimize),
                    f'{label}: child did not use the requested optimization level')
        print(f'{label} PYTHONOPTIMIZE={optimize}: '
              f'exit={result.returncode}, checker_called={called}, '
              f'expected_failure={expected_failure!r}', flush=True)


baseline = subprocess.run(
    ['git', 'show', f'{BASE}:tests/test-native-hardening.py'],
    check=True, capture_output=True, text=True, timeout=10).stdout
candidate = (ROOT / 'tests/test-native-hardening.py').read_text()
checker = (ROOT / 'scripts/check-native-hardening.py').read_text()
checker = replace_once(
    checker, 'def violations(path):\n',
    "def violations(path):\n"
    "    Path(os.environ['TERMINAL_CHECKER_MARKER']).write_text(str(sys.flags.optimize))\n")
no_noctty = replace_once(checker, ' | os.O_NOCTTY', '')
wrong_refusal = replace_once(
    checker,
    "if not stat.S_ISREG(os.fstat(descriptor).st_mode):\n"
    "                return ['expected a regular ELF file']",
    "if not stat.S_ISREG(os.fstat(descriptor).st_mode):\n"
    "                return []")

for name, tests in (('baseline', baseline), ('candidate', candidate)):
    for optimize in (0, 1, 2):
        stripped = name == 'baseline' and optimize != 0
        run_case(f'{name}/correct', tests, checker, optimize, None, not stripped)
        run_case(f'{name}/without-O_NOCTTY', tests, no_noctty, optimize,
                 None if stripped else 'checker acquired a controlling terminal', not stripped)
        run_case(f'{name}/wrong-refusal', tests, wrong_refusal, optimize,
                 None if stripped else ('unexpected terminal refusal: []'
                                        if name == 'candidate' else '\nAssertionError\n'),
                 not stripped)
        precondition = ("assert not has_controlling_terminal(), "
                        "'child must start without a controlling terminal'"
                        if name == 'baseline' else
                        "if has_controlling_terminal():\n"
                        "    sys.exit('child must start without a controlling terminal')")
        already_attached = replace_once(
            tests, precondition,
            "descriptor = os.open(sys.argv[2], os.O_RDONLY)\n"
            "os.close(descriptor)\n" + precondition)
        run_case(f'{name}/already-has-terminal', already_attached, checker, optimize,
                 None if stripped else 'child must start without a controlling terminal', False)

sentinel = 'NativeTerminalTests.test_optimized_probe_detects_terminal_acquisition'
run_case('candidate/durable-sentinel', candidate, checker, 2, None, True, sentinel)
restored_asserts = replace_once(
    candidate,
    "if has_controlling_terminal():\n"
    "    sys.exit('child must start without a controlling terminal')\n"
    "violations = runpy.run_path(sys.argv[1])['violations']\n"
    "errors = violations(Path(sys.argv[2]))\n"
    "if errors != ['expected a regular ELF file']:\n"
    "    sys.exit(f'unexpected terminal refusal: {errors!r}')\n"
    "if has_controlling_terminal():\n"
    "    sys.exit('checker acquired a controlling terminal')",
    "assert not has_controlling_terminal(), 'child must start without a controlling terminal'\n"
    "violations = runpy.run_path(sys.argv[1])['violations']\n"
    "assert violations(Path(sys.argv[2])) == ['expected a regular ELF file']\n"
    "assert not has_controlling_terminal(), 'checker acquired a controlling terminal'")
run_case('restored-asserts/durable-sentinel', restored_asserts, checker, 2,
         'AssertionError: 1 != 0 :', False, sentinel)

print('26 expected outcomes matched. Baseline optimized success is vacuous reproduction, '
      'not a passing regression. Candidate controls retained all three checks and invocation.')
