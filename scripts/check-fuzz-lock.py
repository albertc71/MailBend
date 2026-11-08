#!/usr/bin/env python3
"""Preserve shipped dependency identities/edges in fuzz, permitting fuzz-only extras."""
import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
SHARED_ROOTS = ('mailbend-net', 'mailbend-tls')
REFERENCE = re.compile(r'([^\s()]+)(?: ([^\s()]+)(?: \((.+)\))?)?', re.DOTALL)


@dataclass(frozen=True)
class Identity:
    name: str
    version: str
    source: str | None

    def __str__(self):
        return f'{self.name} {self.version} ({self.source or "local"})'


@dataclass
class Package:
    checksum: str | None
    dependencies: list[str]


class Lock:
    def __init__(self, path):
        self.path = path
        self.packages = {}
        try:
            with path.open('rb') as source:
                data = tomllib.load(source)
        except tomllib.TOMLDecodeError as error:
            raise ValueError(f'{path}: {error}') from error
        if type(data.get('version')) is not int or data['version'] not in (3, 4):
            raise ValueError(f'{path}: unsupported lock format version')
        records = data.get('package')
        if not isinstance(records, list):
            raise ValueError(f'{path}: missing package array')
        for record in records:
            if not isinstance(record, dict):
                raise ValueError(f'{path}: invalid package record')
            name, version = record.get('name'), record.get('version')
            source = record.get('source')
            if any(not isinstance(value, str) or not re.fullmatch(r'[^\s()]+', value)
                   for value in (name, version)):
                raise ValueError(f'{path}: invalid package name/version')
            if 'source' in record and (not isinstance(source, str) or not source):
                raise ValueError(f'{path}: {name}: invalid source')
            identity = Identity(name, version, source)
            checksum = record.get('checksum')
            if 'checksum' in record and (not isinstance(checksum, str)
                                        or not re.fullmatch(r'[0-9a-f]{64}', checksum)):
                raise ValueError(f'{path}: {identity}: invalid checksum')
            if source is None and 'checksum' in record:
                raise ValueError(f'{path}: {identity}: local package has checksum')
            if source is not None and source.startswith('registry+') and checksum is None:
                raise ValueError(f'{path}: {identity}: missing registry checksum')
            dependencies = record.get('dependencies', [])
            if not isinstance(dependencies, list) or any(
                    not isinstance(item, str) for item in dependencies):
                raise ValueError(f'{path}: {identity}: invalid dependencies')
            if identity in self.packages:
                raise ValueError(f'{path}: duplicate package {identity}')
            self.packages[identity] = Package(checksum, dependencies)

    def root(self, name):
        matches = [key for key in self.packages if key.name == name and key.source is None]
        if len(matches) != 1:
            raise ValueError(f'{self.path}: expected exactly one local root {name}')
        return matches[0]

    def edges(self, parent):
        result = set()
        for reference in self.packages[parent].dependencies:
            match = REFERENCE.fullmatch(reference)
            if match is None:
                raise ValueError(f'{self.path}: {parent}: malformed reference {reference!r}')
            name, version, source = match.groups()
            matches = [key for key in self.packages
                       if key.name == name and (version is None or key.version == version)
                       and (source is None or key.source == source)]
            if len(matches) != 1:
                kind = 'unresolved' if not matches else 'ambiguous'
                raise ValueError(f'{self.path}: {parent}: {kind} reference {reference!r}')
            result.add(matches[0])
        return result


def check(native, fuzz):
    pending = []
    for name in SHARED_ROOTS:
        root = native.root(name)
        if fuzz.root(name) != root:
            raise ValueError(f'{fuzz.path}: mismatched local root {root}')
        pending.append(root)
    visited = set()
    while pending:
        parent = pending.pop()
        if parent in visited:
            continue
        visited.add(parent)
        if parent not in fuzz.packages:
            raise ValueError(f'{fuzz.path}: missing shared package {parent}')
        if native.packages[parent].checksum != fuzz.packages[parent].checksum:
            raise ValueError(f'{fuzz.path}: checksum mismatch for {parent}')
        shipped_edges = native.edges(parent)
        fuzz_edges = fuzz.edges(parent)
        for target in sorted(shipped_edges, key=str):
            if target not in fuzz_edges:
                raise ValueError(f'{fuzz.path}: missing shared edge {parent} -> {target}')
        pending.extend(sorted(shipped_edges, key=str))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', type=Path, default=ROOT / 'native/Cargo.lock')
    parser.add_argument('--fuzz', type=Path, default=ROOT / 'native/fuzz/Cargo.lock')
    args = parser.parse_args()
    try:
        check(Lock(args.native), Lock(args.fuzz))
    except (OSError, ValueError) as error:
        print(f'fuzz lock check failed: {error}', file=sys.stderr)
        return 1
    print('Shared native dependency identities and edges match the fuzz lock.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
