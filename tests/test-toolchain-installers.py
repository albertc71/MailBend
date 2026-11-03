#!/usr/bin/env python3
"""Offline installer platform/checksum gates. Does not execute downloaded tools."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PINS = {
    'bend': ('63039d1a119f716767ac5a7d8fe0717cfacf219c6c253c35192148e0dade722f', '09b813073241628f590f2c2fe420299ec25e4dddd6cf3fdc49c9486339989564'),
    'lean': ('42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63', '05febd124d84ebf994b2e7479922a5650b1e950c17ae3bd1ddd776b65bb72bf9'),
    'rust': ('dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71', '15f6e4ce9f583b929c996c91562bad6d4454f3281de858b02cdfdef615fac433'),
}


class Installers(unittest.TestCase):
    def run_installer(self, tool, system='Linux', arch='aarch64', bad=False):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            mocks = home / 'mocks'
            mocks.mkdir()
            scripts = {
                'uname': 'case "$1" in -s) echo "$TEST_SYSTEM";; -m) echo "$TEST_ARCH";; esac',
                'curl': '''echo "download $*" >> "$TRACE"
while [ "$1" != -o ]; do shift; done
printf '#!/bin/sh\\necho executed >> "$TRACE"\\n' > "$2"''',
                'sha256sum': '''read -r digest path
printf 'verify %s\\n' "$digest" >> "$TRACE"
[ "$digest" = "$EXPECTED_DIGEST" ] && [ "$BAD_DIGEST" = 0 ]''',
                'tar': '''echo extract >> "$TRACE"
while [ "$1" != -C ]; do shift; done
mkdir -p "$2/bend/bin" "$2/bend/bend2" "$2/bend/guide"
printf '#!/bin/sh\\necho executed >> "$TRACE"\\n' > "$2/elan-init"
chmod +x "$2/elan-init"
touch "$2/bend/bin/bend"''',
            }
            for name, body in scripts.items():
                f = mocks / name
                f.write_text('#!/bin/sh\nset -eu\n' + body + '\n')
                f.chmod(0o755)
            for name in ['.elan/bin/elan', '.cargo/bin/rustup']:
                f = home / name
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text('#!/bin/sh\necho toolchain >> "$TRACE"\n')
                f.chmod(0o755)
            trace = home / 'trace'
            env = dict(os.environ, HOME=str(home), PATH=str(mocks) + ':/usr/bin:/bin',
                       TRACE=str(trace), TEST_SYSTEM=system, TEST_ARCH=arch,
                       EXPECTED_DIGEST=PINS[tool][arch == 'aarch64'], BAD_DIGEST=str(int(bad)))
            result = subprocess.run(['sh', str(ROOT / 'scripts' / f'install-{tool}.sh')],
                                    env=env, capture_output=True, text=True, timeout=10)
            return result, trace.read_text().splitlines() if trace.exists() else []

    def test_supported_platforms_select_verified_assets(self):
        for tool in PINS:
            for arch in ['x86_64', 'aarch64']:
                with self.subTest(tool=tool, arch=arch):
                    result, trace = self.run_installer(tool, arch=arch)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    target = ('x64' if arch == 'x86_64' else 'arm64') if tool == 'bend' else arch
                    self.assertIn(target, trace[0])
                    self.assertTrue(trace[1].startswith('verify '))
                    self.assertIn('extract' if tool != 'rust' else 'executed', trace[2:])

    def test_bad_checksum_never_extracts_or_executes(self):
        for tool in PINS:
            for arch in ['x86_64', 'aarch64']:
                with self.subTest(tool=tool, arch=arch):
                    result, trace = self.run_installer(tool, arch=arch, bad=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('checksum mismatch', result.stderr)
                    self.assertEqual(len(trace), 2)

    def test_unsupported_platforms_never_download(self):
        for tool in PINS:
            for system, arch in [('Darwin', 'aarch64'), ('Linux', 'armv7l'), ('FreeBSD', 'x86_64')]:
                with self.subTest(tool=tool, system=system, arch=arch):
                    result, trace = self.run_installer(tool, system, arch)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(trace, [])


if __name__ == '__main__':
    unittest.main()
