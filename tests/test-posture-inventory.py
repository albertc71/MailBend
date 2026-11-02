#!/usr/bin/env python3
"""A conservative review gate, not a semantic proof of native network behavior."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'tests' / 'posture-egress-inventory.json'


def inventory(root):
    paths = sorted({p for p in (root / 'native').rglob('*') if p.is_file()} |
                   {root / 'scripts/mailbend-cloud'})
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in paths if 'target' not in p.relative_to(root).parts}


def differences(expected, actual):
    return sorted(p for p in set(expected) | set(actual) if expected.get(p) != actual.get(p))


class InventoryTests(unittest.TestCase):
    def test_current_native_routes_are_reviewed(self):
        expected = {item['path']: item['sha256']
                    for item in json.loads(MANIFEST.read_text())['files']}
        changed = differences(expected, inventory(ROOT))
        self.assertEqual([], changed, 'Native code/dependencies changed. Audit every destination, '
                         'DNS/proxy environment read and posture disclosure before updating '
                         f'the inventory hashes. Changed paths: {changed}')

    def test_new_destination_cannot_silently_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'native').mkdir()
            (root / 'scripts').mkdir()
            (root / 'native/Cargo.lock').write_text('')
            (root / 'scripts/mailbend-cloud').write_text('')
            p = root / 'native/routes.rs'
            p.write_text('const HOST: &str = "api.typesafe.ai";')
            baseline = inventory(root)
            p.write_text('const HOST: &str = "new-destination.invalid";')
            self.assertEqual(['native/routes.rs'], differences(baseline, inventory(root)))
            p.write_text('std::env::var("NEW_DNS_PROXY_SETTING");')
            self.assertEqual(['native/routes.rs'], differences(baseline, inventory(root)))
            (root / 'native/new_route.rs').write_text('socket.connect(address);')
            self.assertIn('native/new_route.rs', differences(baseline, inventory(root)))


if __name__ == '__main__':
    unittest.main()
