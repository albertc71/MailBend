#!/usr/bin/env python3
from pathlib import Path
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / 'scripts/check-native-hardening.py'
HELPERS = ('mailbend-tls', 'mailbend-attach', 'mailbend-typesafe', 'mailbend-stdio')


class NativeHardeningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mailbend ELF ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.good = self.compile('good', source='''#include <stdio.h>
int main(void) {
    FILE *file = fopen("executed-helper", "w");
    if (file) fclose(file);
    return 0;
}
''')
        for name in HELPERS:
            shutil.copy2(self.good, self.bin / name)

    def compile(self, name, *flags, source='int main(void) { return 0; }'):
        src = self.root / f'{name}.c'
        src.write_text(source)
        output = self.root / name
        subprocess.run(['cc', '-fPIE', '-pie', '-Wl,-z,relro,-z,now,-z,noexecstack',
                        str(src), *flags, '-o', str(output)], check=True,
                       capture_output=True, text=True, timeout=30)
        return output

    def program_headers(self, data):
        self.assertEqual(b'\x7fELF\x02\x01', data[:6])
        offset = struct.unpack_from('<Q', data, 32)[0]
        size, count = struct.unpack_from('<HH', data, 54)
        for index in range(count):
            position = offset + index * size
            yield position, struct.unpack_from('<IIQQQQQQ', data, position)

    def check(self, env=None):
        return subprocess.run([sys.executable, str(CHECKER), str(self.bin)],
                              capture_output=True, text=True, timeout=60, cwd=self.root, env=env)

    def test_accepts_four_hardened_executables(self):
        # shortcut: one literal helpers= line, update this reader if that contract changes.
        source = (ROOT / 'scripts/install.sh').read_text()
        declarations = [line for line in source.splitlines()
                        if re.search(r'\bhelpers\s*\+?=', line.split('#', 1)[0])]
        self.assertEqual(1, len(declarations),
                         'installer inventory needs exactly one helpers= declaration')
        declaration = re.fullmatch(r'[ \t]*helpers="([a-z0-9 \t-]*)"[ \t]*(?:#.*)?',
                                   declarations[0])
        self.assertIsNotNone(declaration, 'unsupported installer inventory declaration')
        installed = declaration[1].split()
        self.assertTrue(installed, 'installer inventory must not be empty')
        self.assertTrue(all(re.fullmatch(r'mailbend-[a-z0-9]+(?:-[a-z0-9]+)*', name)
                            for name in installed), 'unsupported installer helper name')
        self.assertEqual(len(installed), len(set(installed)),
                         'duplicate installer helper name')
        result = self.check()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('', result.stderr)
        self.assertCountEqual([f'{self.bin / name}: OK' for name in installed],
                              result.stdout.splitlines(),
                              'checker output must cover each installed helper exactly once')
        self.assertCountEqual(installed, HELPERS, 'fixtures must cover every installed helper')
        self.assertFalse((self.root / 'executed-helper').exists())
        self.assertTrue(all(os.access(self.bin / name, os.X_OK) for name in HELPERS))

    def test_rejects_leaf_symlinks_to_hardened_executables(self):
        for name in ('mailbend-tls', 'mailbend-attach', 'mailbend-typesafe', 'mailbend-stdio'):
            with self.subTest(name=name):
                result = self.check()
                self.assertEqual(0, result.returncode, result.stderr)
                path = self.bin / name
                path.unlink()
                path.symlink_to(self.good)
                try:
                    result = self.check()
                    self.assertEqual(1, result.returncode, 'leaf symlink must be refused')
                    self.assertEqual(f'{path}: expected a regular ELF file\n', result.stderr)
                finally:
                    path.unlink()
                    shutil.copy2(self.good, path)
                    result = self.check()
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertFalse((self.root / 'executed-helper').exists())

    def test_accepts_parent_symlink_but_rejects_leaf_symlink(self):
        alias = self.root / 'bin-alias'
        alias.symlink_to(self.bin, target_is_directory=True)
        self.bin = alias
        result = self.check()
        self.assertEqual(0, result.returncode, result.stderr)
        path = alias / 'mailbend-tls'
        path.unlink()
        path.symlink_to(self.good)
        try:
            result = self.check()
            self.assertEqual(1, result.returncode, 'leaf symlink must be refused')
            self.assertEqual(f'{alias}/mailbend-tls: expected a regular ELF file\n', result.stderr)
        finally:
            path.unlink()
            shutil.copy2(self.good, path)
            result = self.check()
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertFalse((self.root / 'executed-helper').exists())

    def test_rejects_missing_or_non_elf_helpers(self):
        for name in HELPERS:
            with self.subTest(name=name):
                path = self.bin / name
                path.unlink()
                result = self.check()
                self.assertNotEqual(0, result.returncode)
                self.assertIn(name, result.stderr)
                path.write_text('not an ELF file')
                self.assertNotEqual(0, self.check().returncode)
                shutil.copyfile(self.good, path)

    def test_rejects_non_pie_and_shared_objects(self):
        for flags in [('-fno-pie', '-no-pie'), ('-fPIC', '-shared')]:
            with self.subTest(flags=flags):
                bad = self.compile('not-pie', *flags)
                shutil.copyfile(bad, self.bin / HELPERS[0])
                result = self.check()
                self.assertNotEqual(0, result.returncode)
                self.assertIn('PIE', result.stderr)

    def test_rejects_missing_relro(self):
        bad = self.compile('no-relro', '-Wl,-z,norelro')
        shutil.copyfile(bad, self.bin / HELPERS[0])
        result = self.check()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('GNU_RELRO', result.stderr)

    def test_inspects_opened_elf_when_path_is_replaced(self):
        real_readelf = shutil.which('readelf')
        self.assertIsNotNone(real_readelf)
        real_readelf = str(Path(real_readelf).resolve())
        version = subprocess.run([real_readelf, '--version'], check=True,
                                 capture_output=True, text=True, timeout=10)
        self.assertIn('GNU readelf', version.stdout)
        bad = self.compile('no-relro', '-Wl,-z,norelro')
        wrappers = self.root / 'tools'
        wrappers.mkdir()
        wrapper = wrappers / 'readelf'
        wrapper.write_text(f'#!{sys.executable}\n' + '''import os
import sys
from pathlib import Path
replacement = Path(os.environ['ELF_REPLACEMENT'])
if replacement.exists():
    os.replace(replacement, os.environ['ELF_ORIGINAL'])
    Path(os.environ['ELF_SWAPPED']).write_text('replaced')
os.execv(os.environ['ELF_READELF'], [os.environ['ELF_READELF'], *sys.argv[1:]])
''')
        wrapper.chmod(0o755)
        path = self.bin / HELPERS[0]
        replacement = self.root / 'replacement'
        swapped = self.root / 'swapped'
        env = {**os.environ, 'PATH': str(wrappers), 'ELF_READELF': real_readelf,
               'ELF_ORIGINAL': str(path), 'ELF_REPLACEMENT': str(replacement),
               'ELF_SWAPPED': str(swapped)}
        for original, later, rejected in ((bad, self.good, True),
                                          (self.good, bad, False),
                                          (self.good, self.good, False)):
            with self.subTest(original=original.name, replacement=later.name):
                shutil.copyfile(original, path)
                shutil.copyfile(later, replacement)
                swapped.unlink(missing_ok=True)
                result = self.check(env=env)
                self.assertEqual('replaced', swapped.read_text())
                self.assertEqual(later.read_bytes(), path.read_bytes())
                self.assertEqual(int(rejected), result.returncode, result.stderr)
                if rejected:
                    self.assertEqual(f'{path}: missing nonempty GNU_RELRO segment\n',
                                     result.stderr)
                else:
                    self.assertEqual('', result.stderr)
                    self.assertIn(f'{path}: OK', result.stdout.splitlines())
                self.assertFalse((self.root / 'executed-helper').exists())

    def test_accepts_hard_linked_regular_helpers(self):
        for name in HELPERS:
            path = self.bin / name
            path.unlink()
            os.link(self.good, path)
        result = self.check()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('', result.stderr)
        self.assertFalse((self.root / 'executed-helper').exists())

    def test_rejects_lazy_binding(self):
        bad = self.compile('lazy', '-Wl,-z,lazy')
        shutil.copyfile(bad, self.bin / HELPERS[0])
        result = self.check()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('BIND_NOW', result.stderr)

    def test_rejects_executable_stack_in_every_helper(self):
        bad = self.compile('exec-stack', '-Wl,-z,execstack')
        for name in HELPERS:
            with self.subTest(name=name):
                shutil.copyfile(bad, self.bin / name)
                result = self.check()
                self.assertNotEqual(0, result.returncode)
                self.assertIn(name, result.stderr)
                self.assertIn('GNU_STACK', result.stderr)
                shutil.copyfile(self.good, self.bin / name)

    def test_rejects_unexpected_dependency(self):
        self.compile('libunexpected.so', '-fPIC', '-shared',
                     '-Wl,-soname,libunexpected.so', source='int extra(void) { return 7; }')
        bad = self.compile('extra', '-L' + str(self.root), '-lunexpected',
                           source='extern int extra(void); int main(void) { return extra(); }')
        shutil.copyfile(bad, self.bin / HELPERS[0])
        result = self.check()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('libunexpected.so', result.stderr)

    def test_rejects_wrong_interpreter(self):
        bad = self.compile('bad-loader', '-Wl,--dynamic-linker=/unexpected/ld.so')
        shutil.copyfile(bad, self.bin / HELPERS[0])
        result = self.check()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('interpreter', result.stderr)

    def test_missing_readelf_fails_closed(self):
        result = self.check(env={**os.environ, 'PATH': str(self.root / 'no-tools')})
        self.assertNotEqual(0, result.returncode)
        self.assertIn('readelf', result.stderr)

    def test_rejects_truncated_elf(self):
        (self.bin / HELPERS[0]).write_bytes(self.good.read_bytes()[:64])
        result = self.check()
        self.assertNotEqual(0, result.returncode)
        self.assertIn(HELPERS[0], result.stderr)

    def test_rejects_archive_containing_hardened_elf(self):
        archive = self.root / 'archive.a'
        subprocess.run(['ar', 'rcs', str(archive), str(self.good)],
                       check=True, capture_output=True, text=True, timeout=30)
        shutil.copy2(archive, self.bin / HELPERS[0])
        result = self.check()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('ELF', result.stderr)

    def test_rejects_fifo_without_waiting_for_a_writer(self):
        path = self.bin / HELPERS[0]
        path.unlink()
        os.mkfifo(path)
        result = self.check()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('regular ELF file', result.stderr)

    def test_rejects_absent_stack_header(self):
        data = bytearray(self.good.read_bytes())
        found = False
        for position, header in self.program_headers(data):
            if header[0] == 0x6474e551:
                struct.pack_into('<I', data, position, 0)
                found = True
        self.assertTrue(found, 'compiler fixture must have GNU_STACK before removing it')
        (self.bin / HELPERS[0]).write_bytes(data)
        result = self.check()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('GNU_STACK', result.stderr)

    def test_accepts_each_immediate_binding_representation(self):
        for representation in ('BIND_NOW', 'FLAGS', 'FLAGS_1'):
            with self.subTest(representation=representation):
                data = bytearray(self.good.read_bytes())
                entries = {}
                for _, header in self.program_headers(data):
                    if header[0] == 2:
                        for position in range(header[2], header[2] + header[5], 16):
                            tag, value = struct.unpack_from('<QQ', data, position)
                            if tag == 0:
                                break
                            entries[tag] = (position, value)
                self.assertIn(30, entries, 'fixture must provide DT_FLAGS')
                self.assertIn(0x6ffffffb, entries, 'fixture must provide DT_FLAGS_1')
                self.assertNotIn(24, entries, 'fixture must not provide an independent DT_BIND_NOW')
                position, value = entries[30]
                if representation == 'BIND_NOW':
                    struct.pack_into('<QQ', data, position, 24, 0)
                elif representation == 'FLAGS_1':
                    struct.pack_into('<Q', data, position + 8, value & ~8)
                position, value = entries[0x6ffffffb]
                if representation != 'FLAGS_1':
                    struct.pack_into('<Q', data, position + 8, value & ~1)
                (self.bin / HELPERS[0]).write_bytes(data)
                result = self.check()
                self.assertEqual(0, result.returncode, result.stderr)


if __name__ == '__main__':
    unittest.main()
