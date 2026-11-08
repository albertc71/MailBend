#!/usr/bin/env python3
"""Check installed native helpers without executing them."""
import argparse
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

HELPERS = ('mailbend-tls', 'mailbend-attach', 'mailbend-typesafe', 'mailbend-stdio')
LOADERS = {'Advanced Micro Devices X86-64': '/lib64/ld-linux-x86-64.so.2',
           'AArch64': '/lib/ld-linux-aarch64.so.1'}


def violations(path):
    try:
        if not stat.S_ISREG(path.lstat().st_mode):
            return ['expected a regular ELF file']
        with path.open('rb') as binary:
            identity = binary.read(16)
        if len(identity) != 16 or identity[:7] != b'\x7fELF\x02\x01\x01':
            return ['expected a direct little-endian ELF64 file']
        result = subprocess.run(['readelf', '-W', '-h', '-l', '-d', str(path.resolve())],
                                env={**os.environ, 'LC_ALL': 'C'},
                                capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
        return [f'cannot inspect ELF: {error}']
    if result.returncode or result.stderr.strip():
        return [f'readelf failed: {result.stderr.strip()}']
    header = dict(re.findall(r'^[ \t]*([^:\n]+):[ \t]+([^\n]+)$',
                             result.stdout.split('Program Headers:')[0], re.M))
    dynamic = re.findall(r'^[ \t]*0x[0-9a-f]+[ \t]+\(([^)]+)\)[ \t]*(.*)$',
                         result.stdout, re.M)
    tags = {}
    for tag, value in dynamic:
        tags.setdefault(tag, []).append(value)
    flags1 = set(' '.join(tags.get('FLAGS_1', [])).split())
    flags = set(' '.join(tags.get('FLAGS', [])).split())
    errors = []
    if (header.get('Class') != 'ELF64'
            or header.get('Data') != "2's complement, little endian"
            or header.get('Machine') not in LOADERS
            or header.get('OS/ABI') not in {'UNIX - System V', 'UNIX - GNU'}):
        errors.append('expected supported little-endian Linux ELF64 architecture')
    if not header.get('Type', '').startswith('DYN ') or 'PIE' not in flags1:
        errors.append('expected PIE executable, not a shared object or fixed executable')
    segments = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if fields and fields[0] in {'GNU_RELRO', 'GNU_STACK', 'INTERP'}:
            if len(fields) < 7 or not all(re.fullmatch(r'0x[0-9a-f]+', x) for x in fields[1:6]):
                return ['cannot parse ELF program headers']
            segments.setdefault(fields[0], []).append(fields)
    relro = segments.get('GNU_RELRO', [])
    if len(relro) != 1 or int(relro[0][5], 16) == 0:
        errors.append('missing nonempty GNU_RELRO segment')
    if not ('BIND_NOW' in tags or 'BIND_NOW' in flags or 'NOW' in flags1):
        errors.append('missing immediate binding (BIND_NOW)')
    stack = segments.get('GNU_STACK', [])
    if (len(stack) != 1 or not stack[0][6:-1]
            or set(''.join(stack[0][6:-1])) - {'R', 'W'}):
        errors.append('missing or executable GNU_STACK segment')
    allowed = {'libc.so.6', 'libgcc_s.so.1'}
    loader = LOADERS.get(header.get('Machine'))
    if loader:
        allowed.add(Path(loader).name)
    interpreters = re.findall(r'^[ \t]*\[Requesting program interpreter: ([^\]\n]+)\]$',
                              result.stdout, re.M)
    if len(segments.get('INTERP', [])) != 1 or not loader or interpreters != [loader]:
        errors.append('missing or incorrect architecture-specific Linux interpreter')
    for value in tags.get('NEEDED', []):
        match = re.fullmatch(r'Shared library: \[([^\[\]]+)\]', value)
        if not match:
            errors.append('cannot parse NEEDED entry')
        elif match[1] not in allowed:
            errors.append(f'unexpected NEEDED library: {match[1]}')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', nargs='?', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'bin')
    args = parser.parse_args()
    failed = False
    for name in HELPERS:
        path = args.directory / name
        errors = violations(path)
        if errors:
            failed = True
            for error in errors:
                print(f'{path}: {error}', file=sys.stderr)
        else:
            print(f'{path}: OK')
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
