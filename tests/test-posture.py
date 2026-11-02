#!/usr/bin/env python3
"""Run the compiled offline report with POSIX network/exec/secret-open denial."""
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / 'bin/mailbend-core'


class PostureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='mailbend-posture-')
        cls.work = Path(cls.tmp.name)
        cls.guard = cls.work / 'guard.so'
        cc = shutil.which('cc')
        if not cc:
            raise RuntimeError('C compiler required for the offline boundary test')
        subprocess.run([cc, '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'tests/posture-guard.c'), '-ldl', '-o', str(cls.guard)], check=True)
        cls.password = cls.work / 'private-password-fifo'
        cls.key = cls.work / 'private-key-fifo'
        os.mkfifo(cls.password)
        os.mkfifo(cls.key)
        cls.log = cls.work / 'guard.log'
        cls.marker = cls.work / 'helper-ran'
        cls.helper = cls.work / 'helper'
        cls.helper.write_text(f'#!/bin/sh\nprintf called > "{cls.marker}"\nexit 99\n')
        cls.helper.chmod(0o700)
        cls.env = {
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'HOME': str(cls.work), 'BEND_NO_TELEMETRY': '1',
            'LD_PRELOAD': str(cls.guard), 'POSTURE_GUARD_LOG': str(cls.log),
            'MAILBEND_PASSWORD_FILE': str(cls.password),
            'MAILBEND_TYPESAFE_KEY_FILE': str(cls.key),
            'MAILBEND_TLS_HELPER': str(cls.helper),
            'MAILBEND_ATTACH_HELPER': str(cls.helper),
            'MAILBEND_TYPESAFE_HELPER': str(cls.helper),
        }
        probe = cls.work / 'probe.c'
        probe.write_text('#include <fcntl.h>\n#include <stdlib.h>\n#include <sys/socket.h>\n'
                         '#include <unistd.h>\n#include <spawn.h>\nint main(void) { char *a[]={"/bin/true",0}; pid_t p; '
                         'open(getenv("MAILBEND_PASSWORD_FILE"),O_RDONLY); '
                         'socket(AF_INET,SOCK_STREAM,0); execve(a[0],a,a); '
                         'posix_spawnp(&p,a[0],0,0,a,a); return 0; }\n')
        cls.probe = cls.work / 'probe'
        subprocess.run([cc, str(probe), '-o', str(cls.probe)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_posture(self, settings=None, args=('diagnose', '--posture'), success=True):
        self.log.unlink(missing_ok=True)
        env = self.env | (settings or {})
        run = subprocess.run([str(CORE), *args], env=env, text=True, capture_output=True, timeout=15)
        self.assertEqual(0 if success else 1, run.returncode, run.stdout + run.stderr)
        self.assertFalse(self.log.exists(), self.log.read_text() if self.log.exists() else '')
        self.assertFalse(self.marker.exists())
        for value in ('synthetic-password-117', 'account-canary@example.test',
                      'recipient-canary@example.test', 'proxy-secret-canary',
                      'url-secret-canary', str(self.work)):
            self.assertNotIn(value, run.stdout + run.stderr)
        return json.loads(run.stdout)

    def test_denial_instrumentation_observes_forbidden_operations(self):
        self.log.unlink(missing_ok=True)
        subprocess.run([str(self.probe)], env=self.env, check=True, timeout=5)
        self.assertEqual(['secret-open', 'socket', 'exec', 'spawn'], self.log.read_text().splitlines())
        self.log.unlink()

    def test_default_without_password_or_network(self):
        data = self.run_posture()
        self.assertTrue(data['offline'])
        self.assertEqual('unrestricted', data['capabilities']['send'])
        self.assertIsNone(data['egress']['typesafe'])
        self.assertEqual({'host': 'imap.mail.me.com', 'port': 993}, data['egress']['imap']['endpoint'])

    def test_switch_matrix_and_redaction(self):
        for ro, drafts, mode in itertools.product((False, True), (False, True), ('off', 'headers', 'body')):
            with self.subTest(ro=ro, drafts=drafts, mode=mode):
                env = {
                    'MAILBEND_READ_ONLY': str(int(ro)), 'MAILBEND_DRAFTS_ONLY': str(int(drafts)),
                    'MAILBEND_TYPESAFE': str(int(mode != 'off')),
                    'MAILBEND_TYPESAFE_CONTENT': 'body' if mode == 'body' else 'headers',
                    'MAILBEND_TYPESAFE_ZERO_RETENTION': str(int(mode == 'body')),
                    'MAILBEND_TYPESAFE_IMAGES': str(int(mode == 'body')),
                    'MAILBEND_APP_PASSWORD': 'synthetic-password-117',
                    'MAILBEND_EMAIL': 'account-canary@example.test',
                    'MAILBEND_ALLOWED_RECIPIENTS': 'recipient-canary@example.test,@allowed.test',
                    'MAILBEND_MAX_SENDS_PER_DAY': '12', 'MAILBEND_STATE_DIR': str(self.work / 'state'),
                    'MAILBEND_ATTACH_DIR': str(self.work / 'attach'),
                    'MAILBEND_DOWNLOAD_DIR': str(self.work / 'download'),
                    'MAILBEND_DOH_URL': 'https://dns.example.test/private?url-secret-canary',
                    'https_proxy': 'http://user:proxy-secret-canary@proxy.example.test:3128/',
                    'no_proxy': 'api.typesafe.ai',
                }
                d = self.run_posture(env)
                c, e = d['capabilities'], d['egress']
                self.assertEqual(not ro, c['state_change'])
                self.assertEqual('none' if ro or drafts else 'allowlist', c['send'])
                self.assertEqual(not (ro or drafts), e['smtp_send_permitted'])
                self.assertIn('conservatively', d['scope'])
                self.assertEqual(2, c['allowlist_entries'])
                self.assertEqual(12, c['daily_cap'])
                self.assertEqual(mode == 'body', c['body_permission'])
                self.assertEqual(mode == 'body', c['image_permission'])
                self.assertTrue(e['doh_proxied'])
                self.assertEqual({'host': 'dns.example.test', 'port': 443}, e['doh'])
                if mode != 'off':
                    self.assertFalse(e['typesafe']['proxied'])
                    self.assertEqual(['mail_get', 'mail_classify', 'mail_triage', 'mail_delete',
                                      'mail_send', 'mail_reply', 'mail_forward'] if mode == 'body' else [],
                                     e['typesafe']['message_text'])
                    self.assertEqual(['mail_classify'] if mode == 'body' else [], e['typesafe']['images'])

    def test_configured_trust_source_without_opening_paths(self):
        fifo = str(self.password)
        cases = [
            ({}, 'system'),
            ({'SSL_CERT_FILE': ''}, 'ssl_cert_env'),
            ({'SSL_CERT_FILE': fifo}, 'ssl_cert_env'),
            ({'SSL_CERT_DIR': ''}, 'system'),
            ({'SSL_CERT_DIR': ':::'}, 'system'),
            ({'SSL_CERT_DIR': ':' + fifo + '::'}, 'ssl_cert_env'),
            ({'SSL_CERT_DIR': ' '}, 'ssl_cert_env'),
            ({'SSL_CERT_FILE': '', 'SSL_CERT_DIR': fifo}, 'ssl_cert_env'),
            ({'MAILBEND_CA_FILE': '', 'SSL_CERT_FILE': fifo}, 'ssl_cert_env'),
            ({'MAILBEND_CA_FILE': '', 'SSL_CERT_DIR': '::'}, 'system'),
            ({'MAILBEND_CA_FILE': fifo}, 'mailbend_ca_file'),
            ({'MAILBEND_CA_FILE': fifo, 'SSL_CERT_FILE': '', 'SSL_CERT_DIR': fifo},
             'mailbend_ca_file'),
        ]
        for settings, source in cases:
            with self.subTest(settings=settings):
                d = self.run_posture(settings)
                self.assertEqual(source, d['egress']['trust_source'])
                self.assertIn('not opened or validated', d['egress']['trust_source_scope'])

    def test_jev_off_image_permission_is_not_active_egress(self):
        d = self.run_posture({'MAILBEND_TYPESAFE_CONTENT': 'body',
                             'MAILBEND_TYPESAFE_ZERO_RETENTION': '1', 'MAILBEND_TYPESAFE_IMAGES': '1'})
        self.assertTrue(d['capabilities']['image_permission'])
        self.assertFalse(d['capabilities']['body_permission'])
        self.assertIsNone(d['egress']['typesafe'])

    def test_malformed_settings_fail_without_echo(self):
        for env, expected in [
            ({'MAILBEND_READ_ONLY': 'yes'}, 'configuration error: MAILBEND_READ_ONLY'),
            ({'MAILBEND_TYPESAFE_API_KEY': 'synthetic-password-117'},
             'configuration error: MAILBEND_TYPESAFE_API_KEY'),
            ({'MAILBEND_TYPESAFE_CONTENT': 'bad'}, 'configuration error: MAILBEND_TYPESAFE_CONTENT'),
            ({'MAILBEND_ALLOWED_RECIPIENTS': 'recipient-canary@example.test,broken'},
             'MAILBEND_ALLOWED_RECIPIENTS contains an invalid entry'),
            ({'MAILBEND_SMTP_TLS_MODE': ''}, 'MAILBEND_SMTP_TLS_MODE must'),
            ({'MAILBEND_SMTP_PORT': '65536'}, 'MAILBEND_SMTP_HOST/PORT'),
            ({'MAILBEND_IMAP_HOST': 'account-canary@example.test'}, 'MAILBEND_IMAP_HOST/PORT'),
            ({'MAILBEND_DOH_URL': 'https://account-canary@example.test/private'}, 'MAILBEND_DOH_URL'),
            ({'https_proxy': 'socks5://proxy.example.test',
              'MAILBEND_DOH_URL': 'https://dns.test'}, 'the HTTPS proxy setting'),
        ]:
            with self.subTest(env=list(env)):
                d = self.run_posture(env, success=False)
                self.assertIn(expected, d['error'])

    def test_proxy_precedence_and_bypass(self):
        env = {'https_proxy': 'http://one.test', 'HTTPS_PROXY': 'http://two.test',
               'all_proxy': 'http://three.test', 'ALL_PROXY': 'http://four.test',
               'MAILBEND_DOH_URL': 'https://DNS.Example.TEST./query', 'no_proxy': '.example.test.'}
        d = self.run_posture(env)
        self.assertEqual('one.test', d['egress']['configured_https_proxy']['host'])
        self.assertFalse(d['egress']['doh_proxied'])
        d = self.run_posture(env | {'https_proxy': '', 'no_proxy': '*', 'NO_PROXY': 'ignored.test'})
        self.assertEqual('two.test', d['egress']['configured_https_proxy']['host'])
        self.assertFalse(d['egress']['doh_proxied'])

    def test_unused_or_bypassed_invalid_proxy_is_not_a_transport_error(self):
        d = self.run_posture({'HTTPS_PROXY': 'socks5://proxy.test:1080'})
        self.assertTrue(d['egress']['proxy_setting_set'])
        self.assertIsNone(d['egress']['configured_https_proxy'])
        d = self.run_posture({'HTTPS_PROXY': 'socks5://proxy.test:1080',
                             'MAILBEND_DOH_URL': 'https://dns.test', 'NO_PROXY': '*'})
        self.assertFalse(d['egress']['doh_proxied'])

    def test_wildcard_is_exact_not_a_normalized_domain(self):
        for bypass in ('*.', '.*'):
            d = self.run_posture({'https_proxy': 'http://proxy.test',
                                 'MAILBEND_DOH_URL': 'https://dns.test', 'no_proxy': bypass})
            self.assertTrue(d['egress']['doh_proxied'])

    def test_numeric_connect_destinations_are_visible(self):
        d = self.run_posture({'MAILBEND_IMAP_CONNECT_IP': '127.0.0.1',
                             'MAILBEND_SMTP_CONNECT_IP': '2001:db8::7'})
        self.assertEqual('127.0.0.1', d['egress']['imap']['connect_ip_override'])
        self.assertEqual('2001:db8::7', d['egress']['smtp']['connect_ip_override'])
        d = self.run_posture({'MAILBEND_IMAP_CONNECT_IP': 'account-canary@example.test'}, success=False)
        self.assertIn('MAILBEND_IMAP_CONNECT_IP must', d['error'])

    def test_network_flags_cannot_mix_with_posture(self):
        for args in [('diagnose', '--posture', '--imap'), ('diagnose', '--smtp', '--posture')]:
            p = subprocess.run([str(CORE), *args], env=self.env, capture_output=True, timeout=15)
            self.assertEqual(2, p.returncode)


if __name__ == '__main__':
    unittest.main()
