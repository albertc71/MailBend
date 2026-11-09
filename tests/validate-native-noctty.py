#!/usr/bin/env python3
"""Hosted-only controls for terminal refusal and retained ELF identity."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / 'scripts/check-native-hardening.py'
TESTS = ROOT / 'tests/test-native-hardening.py'


def run_test(checker, method, failures=0, expected_failure=None):
    with tempfile.TemporaryDirectory(prefix='elf-mutation-') as temporary:
        root = Path(temporary)
        (root / 'scripts').mkdir()
        (root / 'tests').mkdir()
        (root / 'scripts/check-native-hardening.py').write_text(checker)
        shutil.copy2(ROOT / 'scripts/install.sh', root / 'scripts/install.sh')
        shutil.copy2(TESTS, root / 'tests/test-native-hardening.py')
        result = subprocess.run([sys.executable, str(root / 'tests/test-native-hardening.py'),
                                 method],
                                capture_output=True, text=True, timeout=120)
        print(result.stderr, end='')
        if failures:
            assert result.returncode == 1, result
            assert f'FAILED (failures={failures})' in result.stderr, result.stderr
            assert 'ERROR:' not in result.stderr, result.stderr
            if expected_failure:
                assert expected_failure in result.stderr, result.stderr
        else:
            assert result.returncode == 0 and '\nOK\n' in result.stderr, result.stderr


source = CHECKER.read_text()
terminal = 'NativeTerminalTests.test_rejects_terminal_without_acquiring_it'
run_test(source, terminal)
needle = ' | os.O_NOCTTY'
assert source.count(needle) == 1
run_test(source.replace(needle, ''), terminal, failures=1,
         expected_failure='checker acquired a controlling terminal')
print('Removing O_NOCTTY acquired the real PTY as a controlling terminal; the retained flag prevented it.')
identity = 'NativeHardeningTests.test_inspects_opened_elf_when_path_is_replaced'
run_test(source, identity)
needle = "f'/proc/self/fd/{descriptor}'"
assert source.count(needle) == 1
run_test(source.replace(needle, 'str(path.resolve())'), identity, failures=2)
print('Pathname-inspection mutant rejected by both real-ELF metadata oracles.')
needle = ' | os.O_NOFOLLOW'
assert source.count(needle) == 1
run_test(source.replace(needle, ''), 'NativeHardeningTests.test_rejects_leaf_symlinks_to_hardened_executables',
         failures=4)
print('Leaf-follow mutant rejected for all four helper names.')

probe = r'''
from pathlib import Path
import errno
import os
import runpy
import subprocess
import sys
from unittest.mock import patch

checker = runpy.run_path(sys.argv[1])
fixtures = runpy.run_path(sys.argv[2])
case = fixtures['NativeHardeningTests']()
try:
    case.setUp()
    path = case.bin / 'mailbend-tls'
    real_open = os.open
    for mode in ('normal', 'symlink', 'fifo', 'short', 'readelf_error',
                 'readelf_timeout', 'readelf_decode', 'readelf_bad_status'):
        if path.exists() or path.is_symlink():
            path.unlink()
        path.write_bytes(case.good.read_bytes() if mode != 'short' else b'ELF')
        opened = []
        def acquire(target, flags, *args, **kwargs):
            if Path(target) == path:
                if mode in ('symlink', 'fifo'):
                    path.unlink()
                    if mode == 'symlink':
                        path.symlink_to(case.good)
                    else:
                        os.mkfifo(path)
                descriptor = real_open(target, flags, *args, **kwargs)
                opened.append(descriptor)
                return descriptor
            return real_open(target, flags, *args, **kwargs)
        real_run = subprocess.run
        def inspect(*args, **kwargs):
            if mode == 'readelf_error':
                raise OSError('injected readelf acquisition failure')
            if mode == 'readelf_timeout':
                raise subprocess.TimeoutExpired('readelf', 10)
            if mode == 'readelf_decode':
                raise UnicodeError('injected decode failure')
            if mode == 'readelf_bad_status':
                return subprocess.CompletedProcess(args[0], 1, '', 'injected readelf failure')
            return real_run(*args, **kwargs)
        with patch.object(os, 'open', acquire), patch.object(subprocess, 'run', inspect):
            errors = checker['violations'](path)
        if mode == 'normal':
            assert errors == [], errors
        elif mode in ('symlink', 'fifo'):
            assert errors == ['expected a regular ELF file'], errors
        elif mode == 'short':
            assert errors == ['expected a direct little-endian ELF64 file'], errors
        else:
            assert len(errors) == 1 and ('cannot inspect ELF' in errors[0]
                                        or 'readelf failed' in errors[0]), errors
        for descriptor in opened:
            try:
                os.fstat(descriptor)
            except OSError as error:
                assert error.errno == errno.EBADF, error
            else:
                raise AssertionError('checker descriptor leaked')
        assert len(opened) == (0 if mode == 'symlink' else 1), opened
        assert not (case.root / 'executed-helper').exists()
        print('Supplemental acquisition/closure control:', mode)
finally:
    case.doCleanups()
'''
result = subprocess.run([sys.executable, '-c', probe, str(CHECKER), str(TESTS)],
                        capture_output=True, text=True, timeout=120)
print(result.stdout, end='')
print(result.stderr, end='', file=sys.stderr)
assert result.returncode == 0, result
print('Acquisition schedules and injected failure cleanup passed. These are instrumentation, not naturally reproduced races or timeout evidence.')
