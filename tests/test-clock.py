#!/usr/bin/env python3
"""Clock failures through the compiled CLI/MCP and synthetic mail server."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('clock_e2e', ROOT / 'tests/test-e2e.py')
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)
SEND = {'to': ['friend@example.com'], 'subject': 'Synthetic clock test', 'body': 'Synthetic.'}


class ClockTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='mailbend-clock-')
        cls.work = Path(cls.tmp.name)
        cls.guard = cls.work / 'guard.so'
        subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'tests/clock-guard.c'), '-ldl', '-o', str(cls.guard)], check=True)
        subprocess.run(['sh', str(ROOT / 'tests/gen-test-certs.sh'), str(cls.work / 'certs')],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.date = cls.work / 'date'
        cls.date.write_text('#!' + sys.executable + '\nimport os, sys, time\nfrom pathlib import Path\n'
                            'time.sleep(float(os.environ.get("CLOCK_TEST_DELAY", "0")))\n'
                            'value = os.environ.get("CLOCK_TEST_OUTPUT", "1700000000\\n")\n'
                            'if len(Path(os.environ["CLOCK_TEST_LOG"]).read_text().splitlines()) == 1:\n'
                            '    value = os.environ.get("CLOCK_TEST_FIRST_OUTPUT", value)\n'
                            'sys.stdout.write(value)\n'
                            'sys.exit(int(os.environ.get("CLOCK_TEST_EXIT", "0")))\n')
        cls.date.chmod(0o700)
        probe = cls.work / 'probe.c'
        probe.write_text('#include <spawn.h>\n#include <string.h>\n#include <sys/wait.h>\n'
                         '#include <unistd.h>\nextern char **environ;\n'
                         'int main(int n, char **v) { if(n!=3) return 98; '
                         'char *a[]={v[2],"+%s",0}; pid_t p; int code; '
                         'if(!strcmp(v[1],"exec")) return execve(v[2],a,environ)<0 ? 99 : 0; '
                         'code=!strcmp(v[1],"spawn") ? posix_spawn(&p,v[2],0,0,a,environ) '
                         ': posix_spawnp(&p,v[2],0,0,a,environ); '
                         'if(code) return 99; if(waitpid(p,&code,0)<0) return 98; '
                         'return WIFEXITED(code) ? WEXITSTATUS(code) : 98; }\n')
        cls.probe = cls.work / 'probe'
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', str(probe), '-o', str(cls.probe)],
                       check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.cell = Path(tempfile.mkdtemp(dir=self.work))
        (self.cell / 'certs').symlink_to(self.work / 'certs', target_is_directory=True)
        self.srv = e2e.Server(str(self.cell), fixture=self.mailbox_fixture())
        self.addCleanup(self.srv.stop)
        self.date_log = self.cell / 'date.log'
        self.helper_log = self.cell / 'helper.jsonl'
        self.counter = self.cell / 'counter'
        recorder = self.cell / 'attach-recorder'
        recorder.write_text('#!' + sys.executable + '\nimport json, os, sys\n'
                            f'with open({str(self.helper_log)!r}, "a") as out:\n'
                            '    out.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                            f'os.execv({str(ROOT / "bin/mailbend-attach")!r}, '
                            f'[{str(ROOT / "bin/mailbend-attach")!r}, *sys.argv[1:]])\n')
        recorder.chmod(0o700)
        self.env = {
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(self.cell),
            'BEND_NO_TELEMETRY': '1', 'LD_PRELOAD': str(self.guard),
            'CLOCK_TEST_LOG': str(self.date_log), 'CLOCK_TEST_HELPER': str(self.date),
            'MAILBEND_EMAIL': e2e.FIX['user'], 'MAILBEND_APP_PASSWORD': e2e.PASSWORD,
            'MAILBEND_IMAP_HOST': 'localhost', 'MAILBEND_IMAP_PORT': self.srv.imap,
            'MAILBEND_SMTP_HOST': 'localhost', 'MAILBEND_SMTP_PORT': self.srv.smtp,
            'MAILBEND_SMTP_TLS_MODE': 'starttls', 'MAILBEND_CA_FILE': str(self.work / 'certs/ca.pem'),
            'MAILBEND_TLS_HELPER': str(ROOT / 'bin/mailbend-tls'),
            'MAILBEND_ATTACH_HELPER': str(recorder), 'MAILBEND_SAVE_SENT': '0',
            'MAILBEND_MAX_SENDS_PER_DAY': '3', 'MAILBEND_STATE_DIR': str(self.counter),
        }

    def mailbox_fixture(self):
        return None

    def call(self, tool='mail_send', args=None, settings=None, wire='cli'):
        self.date_log.unlink(missing_ok=True)
        self.helper_log.unlink(missing_ok=True)
        self.log_start = len(self.srv.log_records())
        env = self.env | (settings or {})
        args = SEND if args is None else args
        if wire == 'cli':
            command = [str(ROOT / 'bin/mailbend-core'), 'call', tool, json.dumps(args)]
            data = None
        else:
            command = [str(ROOT / 'bin/mailbend-core'), 'mcp']
            data = json.dumps({'jsonrpc': '2.0', 'id': 'clock-init', 'method': 'initialize',
                               'params': {'protocolVersion': '2025-06-18'}}) + '\n'
            data += json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                               'params': {'name': tool, 'arguments': args}}) + '\n'
        run = subprocess.run(command, env=env, input=data, text=True, capture_output=True, timeout=20)
        self.assertNotIn(e2e.PASSWORD, run.stdout + run.stderr)
        replies = [json.loads(line) for line in run.stdout.splitlines()]
        result = replies[-1]
        if wire == 'mcp':
            self.assertEqual(0, run.returncode, run.stderr)
            self.assertEqual(2, len(replies))
            self.assertEqual('clock-init', replies[0]['id'])
            self.assertEqual(1, result['id'])
            result = result['result']
            self.assertEqual(result['structuredContent'], json.loads(result['content'][0]['text']))
            failed = result['isError']
            result = result['structuredContent']
        else:
            failed = run.returncode != 0
        self.assertTrue(self.date_log.is_file(),
                        'date fault injection did not run: ' + repr((run.returncode, result, run.stderr)))
        return failed, result

    def assert_no_effects(self, before):
        self.assertEqual(before, self.srv.st())
        self.assertFalse(any(r['proto'] == 'smtp' or ' APPEND ' in r['line']
                             for r in self.srv.log_records()[self.log_start:]))
        self.assertFalse(self.helper_log.exists(), 'attachment/counter helper was invoked')
        self.assertFalse(self.counter.exists(), 'counter directory was created')


class ClockTests(ClockTestCase):
    def test_date_interposition_and_other_commands(self):
        for mode in ('exec', 'spawn', 'spawnp'):
            for unavailable in (False, True):
                with self.subTest(mode=mode, unavailable=unavailable):
                    self.date_log.unlink(missing_ok=True)
                    env = self.env | {'CLOCK_TEST_MODE': 'unavailable' if unavailable else 'valid'}
                    run = subprocess.run([str(self.probe), mode, '/bin/date'], env=env,
                                         text=True, capture_output=True, timeout=5)
                    self.assertEqual(99 if unavailable else 0, run.returncode)
                    self.assertEqual('' if unavailable else '1700000000\n', run.stdout)
                    self.assertEqual(['date'], self.date_log.read_text().splitlines())
            self.date_log.unlink()
            run = subprocess.run([str(self.probe), mode, '/bin/true'], env=self.env, timeout=5)
            self.assertEqual(0, run.returncode)
            self.assertFalse(self.date_log.exists())

    def test_unavailable_clock_refuses_send(self):
        before = self.srv.st()
        failed, result = self.call(settings={'CLOCK_TEST_MODE': 'unavailable'})
        self.assertTrue(failed, result)
        self.assertIn('clock', result['error'])
        self.assert_no_effects(before)

    def test_valid_clock_sends_with_current_date_and_counter(self):
        failed, result = self.call()
        self.assertFalse(failed, result)
        self.assertTrue(result['sent'])
        sent = self.srv.st()['sent']
        self.assertEqual(1, len(sent))
        self.assertIn('Date: Tue, 14 Nov 2023 22:13:20 +0000\r\n', sent[0]['data'])
        self.assertEqual('2023-11-14\n', (self.counter / 'sends').read_text())
        calls = [json.loads(line) for line in self.helper_log.read_text().splitlines()]
        self.assertEqual([['count', str(self.counter), '3', '2023-11-14']], calls)
        self.assertEqual(['date', 'date'], self.date_log.read_text().splitlines())

    def test_second_clock_failure_refuses_before_counter_and_smtp(self):
        before = self.srv.st()
        failed, result = self.call(settings={'CLOCK_TEST_MODE': 'second-unavailable'})
        self.assertTrue(failed, result)
        self.assertIn('clock', result['error'])
        self.assertEqual('not_sent', result['smtp_outcome'])
        self.assertEqual('before_smtp', result['smtp_phase'])
        self.assertEqual('local_refusal', result['smtp_reason'])
        self.assertEqual(['date', 'date'], self.date_log.read_text().splitlines())
        self.assert_no_effects(before)

    def test_nonzero_date_exit_refuses_numeric_output(self):
        before = self.srv.st()
        failed, result = self.call(settings={'CLOCK_TEST_EXIT': '1'})
        self.assertTrue(failed, result)
        self.assertIn('clock', result['error'])
        self.assert_no_effects(before)

    def test_initial_clock_faults_refuse_sends_and_drafts(self):
        faults = [
            {'CLOCK_TEST_MODE': 'unavailable'},
            {'CLOCK_TEST_EXIT': '1'},
            *({'CLOCK_TEST_OUTPUT': value} for value in
              ('', '0\n', '-1\n', 'clock-secret-canary\n', '4294967296\n',
               '4294967297\n', '01700000000\n', '+1700000000\n', '1 2\n', '1' * 65)),
        ]
        for wire in ('cli', 'mcp'):
            for tool in ('mail_send', 'mail_save_draft'):
                for settings in faults:
                    with self.subTest(wire=wire, tool=tool, settings=settings):
                        before = self.srv.st()
                        failed, result = self.call(tool, settings=settings, wire=wire)
                        self.assertTrue(failed, result)
                        self.assertIn('clock', result['error'])
                        self.assertNotIn('clock-secret-canary', json.dumps(result))
                        self.assertNotIn('1970', json.dumps(result))
                        self.assert_no_effects(before)

    def test_unknown_clock_refuses_dry_runs(self):
        for wire in ('cli', 'mcp'):
            for tool in ('mail_send', 'mail_save_draft'):
                with self.subTest(wire=wire, tool=tool):
                    before = self.srv.st()
                    failed, result = self.call(tool, SEND | {'dry_run': True},
                                               {'CLOCK_TEST_MODE': 'unavailable'}, wire)
                    self.assertTrue(failed, result)
                    self.assertIn('clock', result['error'])
                    self.assert_no_effects(before)

    def test_second_clock_failure_refuses_without_daily_cap(self):
        for wire in ('cli', 'mcp'):
            with self.subTest(wire=wire):
                before = self.srv.st()
                failed, result = self.call(settings={'CLOCK_TEST_MODE': 'second-unavailable',
                                                     'MAILBEND_MAX_SENDS_PER_DAY': ''}, wire=wire)
                self.assertTrue(failed, result)
                self.assertEqual(('not_sent', 'before_smtp', 'local_refusal'),
                                 (result['smtp_outcome'], result['smtp_phase'], result['smtp_reason']))
                self.assert_no_effects(before)

    def test_valid_clock_saves_draft_without_counter(self):
        failed, result = self.call('mail_save_draft', wire='mcp')
        self.assertFalse(failed, result)
        self.assertEqual('Drafts', result['saved_to'])
        drafts = self.srv.st()['mailboxes']['Drafts']['messages']
        self.assertIn('Date: Tue, 14 Nov 2023 22:13:20 +0000\r\n', drafts[-1]['raw'])
        self.assertTrue(any(' APPEND ' in r['line'] for r in self.srv.log_records()))
        self.assertFalse(any(r['proto'] == 'smtp' for r in self.srv.log_records()))
        self.assertFalse(self.helper_log.exists())
        self.assertFalse(self.counter.exists())
        self.assertEqual(['date'], self.date_log.read_text().splitlines())

    def test_valid_dry_runs_do_not_reserve_or_send(self):
        for tool in ('mail_send', 'mail_save_draft'):
            with self.subTest(tool=tool):
                before = self.srv.st()
                failed, result = self.call(tool, SEND | {'dry_run': True},
                                           {'CLOCK_TEST_MODE': 'second-unavailable'}, 'mcp')
                self.assertFalse(failed, result)
                self.assertTrue(result['dry_run'])
                self.assertEqual(['date'], self.date_log.read_text().splitlines())
                self.assert_no_effects(before)

    def test_reply_and_forward_refuse_unknown_clock(self):
        for tool in ('mail_reply', 'mail_forward'):
            for draft in (False, True):
                with self.subTest(tool=tool, draft=draft):
                    before = self.srv.st()
                    args = {'uid': 1, 'uidvalidity': e2e.FIX['mailboxes']['INBOX']['uidvalidity'],
                            'body': 'Synthetic.', 'as_draft': draft}
                    if tool == 'mail_forward':
                        args['to'] = 'friend@example.com'
                    failed, result = self.call(tool, args, {'CLOCK_TEST_MODE': 'unavailable'}, 'mcp')
                    self.assertTrue(failed, result)
                    self.assertIn('clock', result['error'])
                    self.assert_no_effects(before)

    def test_maximum_u32_clock_is_valid(self):
        failed, result = self.call('mail_save_draft', settings={'CLOCK_TEST_OUTPUT': '4294967295\n'})
        self.assertFalse(failed, result)
        drafts = self.srv.st()['mailboxes']['Drafts']['messages']
        self.assertIn('Date: Sun, 7 Feb 2106 06:28:15 +0000\r\n', drafts[-1]['raw'])

    def test_reservation_uses_second_day_after_midnight(self):
        failed, result = self.call(settings={'CLOCK_TEST_FIRST_OUTPUT': '1700006399\n',
                                             'CLOCK_TEST_OUTPUT': '1700006400\n'})
        self.assertFalse(failed, result)
        sent = self.srv.st()['sent']
        self.assertIn('Date: Tue, 14 Nov 2023 23:59:59 +0000\r\n', sent[0]['data'])
        self.assertEqual('2023-11-15\n', (self.counter / 'sends').read_text())
        calls = [json.loads(line) for line in self.helper_log.read_text().splitlines()]
        self.assertEqual([['count', str(self.counter), '3', '2023-11-15']], calls)

    def test_second_malformed_clock_refuses_before_counter_and_smtp(self):
        before = self.srv.st()
        failed, result = self.call(settings={'CLOCK_TEST_FIRST_OUTPUT': '1700000000\n',
                                             'CLOCK_TEST_OUTPUT': '4294967297\n'}, wire='mcp')
        self.assertTrue(failed, result)
        self.assertEqual(('not_sent', 'before_smtp', 'local_refusal'),
                         (result['smtp_outcome'], result['smtp_phase'], result['smtp_reason']))
        self.assert_no_effects(before)

    def test_date_timeout_refuses_without_mail_or_counter(self):
        before = self.srv.st()
        failed, result = self.call(settings={'CLOCK_TEST_DELAY': '6'}, wire='mcp')
        self.assertTrue(failed, result)
        self.assertIn('clock', result['error'])
        self.assert_no_effects(before)


class BriefClockTestCase(ClockTestCase):
    wires = ('cli', 'mcp')

    def mailbox_fixture(self):
        fixture = copy.deepcopy(e2e.FIX)
        fixture['mailboxes']['INBOX']['messages'] = [{
            'uid': 1, 'flags': [], 'internaldate': '14-Nov-2023 00:00:00 +0000',
            'raw': 'From: known@example.test\r\nTo: tester@example.com\r\n'
                   'Date: Tue, 14 Nov 2023 00:00:00 +0000\r\n'
                   'Message-ID: <brief-clock@example.test>\r\nSubject: Brief\r\n\r\nSynthetic.',
        }]
        fixture['mailboxes']['Sent Messages']['messages'] = [{
            'uid': 1, 'flags': [], 'internaldate': '13-Nov-2023 00:00:00 +0000',
            'raw': 'From: tester@example.com\r\nTo: known@example.test\r\n'
                   'Date: Mon, 13 Nov 2023 00:00:00 +0000\r\n'
                   'Message-ID: <previous-clock@example.test>\r\nSubject: Previous\r\n\r\nSynthetic.',
        }]
        return fixture

    def assert_partial_brief(self, settings, wire):
        before = self.srv.st()
        failed, result = self.call('mail_brief', {'since_uid': 0},
                                   settings | {'MAILBEND_READ_ONLY': '1'}, wire)
        self.assertFalse(failed, result)
        self.assertEqual([1], [m['uid'] for m in result['messages']])
        self.assertEqual('Brief', result['messages'][0]['subject'])
        self.assertEqual('unknown_people', result['messages'][0]['group'])
        self.assertEqual([{'group': 'unknown_people', 'group_key': None, 'count': 1}],
                         result['groups'])
        self.assertEqual(('INBOX', 1700000001), (result['folder'], result['uidvalidity']))
        self.assertEqual(1, result['next_since_uid'])
        self.assertTrue(result['selected_complete'])
        self.assertFalse(result['has_more'])
        self.assertIsNone(result['next_continuation'])
        correspondence = result['correspondence']
        self.assertEqual('', correspondence['since'])
        self.assertEqual((1, 1), (correspondence['selected_senders'],
                                  correspondence['total_senders']))
        coverage = correspondence['coverage']
        self.assertFalse(coverage['complete'])
        self.assertEqual(0, coverage['sampled_headers'])
        self.assertIn('clock', coverage['reason'])
        self.assertIn('window', coverage['reason'])
        commands = [r['line'] for r in self.srv.log_records()[self.log_start:]]
        self.assertFalse(any(' LIST ' in line or ' LSUB ' in line or
                             'Sent Messages' in line or ' SINCE ' in line
                             for line in commands), commands)
        self.assertTrue(any(' UID FETCH ' in line for line in commands), commands)
        self.assertFalse(any(' SELECT ' in line or 'BODY[' in line for line in commands), commands)
        self.assert_no_effects(before)
        self.assertNotIn('clock-secret-canary', json.dumps(result))
        self.assertEqual(['date'], self.date_log.read_text().splitlines())

    def assert_observed_brief(self, settings, wire, since):
        before = self.srv.st()
        failed, result = self.call('mail_brief', {'since_uid': 0},
                                   settings | {'MAILBEND_READ_ONLY': '1'}, wire)
        self.assertFalse(failed, result)
        self.assertEqual([1], [m['uid'] for m in result['messages']])
        self.assertEqual('people', result['messages'][0]['group'])
        self.assertEqual([{'group': 'people', 'group_key': None, 'count': 1}], result['groups'])
        self.assertEqual(('INBOX', 1700000001), (result['folder'], result['uidvalidity']))
        self.assertEqual('Brief', result['messages'][0]['subject'])
        self.assertEqual(1, result['next_since_uid'])
        self.assertTrue(result['selected_complete'])
        self.assertFalse(result['has_more'])
        self.assertIsNone(result['next_continuation'])
        correspondence = result['correspondence']
        self.assertEqual(since, correspondence['since'])
        self.assertEqual({'folder': 'Sent Messages', 'uidvalidity': 1700000004,
                          'sampled_headers': 1, 'complete': True, 'reason': ''},
                         correspondence['coverage'])
        commands = [r['line'] for r in self.srv.log_records()[self.log_start:]]
        self.assertTrue(any(' LIST ' in line for line in commands), commands)
        self.assertTrue(any(' EXAMINE "Sent Messages"' in line for line in commands), commands)
        searches = [line.split(' UID SEARCH ', 1)[1] for line in commands
                    if ' UID SEARCH SINCE ' in line]
        self.assertEqual(['SINCE ' + since + ' UNDELETED'], searches)
        self.assertFalse(any(' SELECT ' in line or 'BODY[' in line for line in commands), commands)
        self.assertEqual(['date'], self.date_log.read_text().splitlines())
        self.assert_no_effects(before)


class BriefClockTests(BriefClockTestCase):
    def test_unknown_clock_keeps_selected_brief_without_correspondence_scan(self):
        for wire in self.wires:
            with self.subTest(wire=wire):
                self.assert_partial_brief({'CLOCK_TEST_MODE': 'unavailable'}, wire)

    def test_failed_or_malformed_clock_keeps_selected_brief(self):
        faults = [
            {'CLOCK_TEST_EXIT': '1'},
            *({'CLOCK_TEST_OUTPUT': value} for value in
              ('', '0\n', 'clock-secret-canary\n', '4294967296\n')),
        ]
        for wire in self.wires:
            for settings in faults:
                with self.subTest(wire=wire, settings=settings):
                    self.assert_partial_brief(settings, wire)

    def test_early_positive_clock_keeps_selected_brief(self):
        for wire in self.wires:
            for value in ('1\n', '2591999\n'):
                with self.subTest(wire=wire, value=value):
                    self.assert_partial_brief({'CLOCK_TEST_OUTPUT': value}, wire)

    def test_valid_clock_observes_known_correspondent(self):
        for wire in self.wires:
            with self.subTest(wire=wire):
                self.assert_observed_brief({'CLOCK_TEST_OUTPUT': '1700000000\n'},
                                           wire, '15-Oct-2023')


class BriefClockBoundaryTests(BriefClockTestCase):
    def mailbox_fixture(self):
        fixture = super().mailbox_fixture()
        for folder in ('INBOX', 'Sent Messages'):
            message = fixture['mailboxes'][folder]['messages'][0]
            message['internaldate'] = '30-Jan-1970 00:00:00 +0000'
            message['raw'] = message['raw'].replace('Tue, 14 Nov 2023', 'Fri, 30 Jan 1970').replace(
                'Mon, 13 Nov 2023', 'Fri, 30 Jan 1970')
        return fixture

    def test_exact_window_clock_observes_known_correspondent(self):
        for wire in self.wires:
            with self.subTest(wire=wire):
                self.assert_observed_brief({'CLOCK_TEST_OUTPUT': '2592000\n'}, wire, '1-Jan-1970')


if __name__ == '__main__':
    unittest.main()
