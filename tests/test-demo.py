#!/usr/bin/env python3
"""Account-free demo boundaries, cleanup, TLS and real MCP tool flow.

--contract-only runs lifecycle/environment cases with an instrumented launcher;
normal runs also require the current checkout's built MailBend binaries.
"""
import argparse
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
DEMO = ROOT / 'scripts/mailbend-demo'
SENTINEL = 'caller-secret-must-not-reach-demo'
POISON = {
    'MAILBEND_APP_PASSWORD': SENTINEL,
    'MAILBEND_PASSWORD_FILE': '/not-a-demo-password-file',
    'MAILBEND_TYPESAFE_KEY_FILE': '/not-a-demo-typesafe-key',
    'MAILBEND_TYPESAFE_API_KEY': SENTINEL,
    'MAILBEND_EMAIL': 'private@example.test',
    'MAILBEND_LOGIN': 'private-login',
    'MAILBEND_TYPESAFE': '1', 'MAILBEND_TYPESAFE_IMAGES': '1',
    'MAILBEND_TYPESAFE_ZERO_RETENTION': '1', 'MAILBEND_TYPESAFE_CONTENT': 'body',
    'MAILBEND_IMAP_HOST': 'remote.example.test', 'MAILBEND_SMTP_HOST': 'remote.example.test',
    'MAILBEND_IMAP_CONNECT_IP': '192.0.2.1', 'MAILBEND_SMTP_CONNECT_IP': '192.0.2.2',
    'MAILBEND_TLS_HELPER': '/not-the-helper', 'MAILBEND_ATTACH_HELPER': '/not-the-helper',
    'MAILBEND_TYPESAFE_HELPER': '/not-the-helper',
    'MAILBEND_ATTACH_DIR': '/private', 'MAILBEND_DOWNLOAD_DIR': '/private',
    'MAILBEND_STATE_DIR': '/private', 'MAILBEND_ALLOWED_RECIPIENTS': '@example.net',
    'MAILBEND_READ_ONLY': 'invalid', 'MAILBEND_DRAFTS_ONLY': 'invalid',
    'MAILBEND_DOH_URL': 'https://remote.example.test/',
    'SSL_CERT_FILE': '/private/ca', 'SSL_CERT_DIR': '/private',
    'https_proxy': 'http://remote.example.test:1234', 'ALL_PROXY': SENTINEL,
    'PYTHONPATH': '/private', 'PYTHONSTARTUP': '/private/start.py',
    'BASH_ENV': '/private/start.sh', 'TMPDIR': '/private',
}


def live(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().split(') ')[1][0] not in 'ZX'
    except FileNotFoundError:
        return False


def until(test, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = test()
        if result:
            return result
        time.sleep(.03)
    raise AssertionError('condition did not become true before timeout')


class Lines:
    def __init__(self, pipe):
        self.queue = queue.Queue()
        def read():
            try:
                for line in pipe:
                    self.queue.put(line)
            finally:
                self.queue.put(b'')
        self.thread = threading.Thread(target=read, daemon=True)
        self.thread.start()

    def json(self, timeout=40):
        return json.loads(self.queue.get(timeout=timeout))


class RunningDemo:
    def __init__(self, root=ROOT, env=None):
        self.proc = subprocess.Popen([str(root / 'scripts/mailbend-demo')],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=dict(os.environ) | POISON | (env or {}))
        self.clients = []
        self.lines = Lines(self.proc.stdout)
        try:
            self.config = self.lines.json()['mcpServers']['mailbend-demo']
            self.work = Path(self.config['args'][1])
        except Exception as error:
            detail = self.proc.stderr.read().decode(errors='replace') if self.proc.poll() is not None else ''
            self.close()
            raise AssertionError('demo startup failed: ' + detail) from error

    def connect(self):
        proc = subprocess.Popen([self.config['command'], *self.config['args']],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=dict(os.environ) | POISON)
        self.clients.append(proc)
        return proc, Lines(proc.stdout)

    def close(self, sig=signal.SIGTERM):
        if self.proc.poll() is None:
            self.proc.send_signal(sig)
        try:
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            raise
        for proc in self.clients:
            try:
                proc.wait(timeout=5)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                for stream in (proc.stdin, proc.stdout, proc.stderr):
                    stream.close()
        self.proc.stdout.close()
        self.proc.stderr.close()


class Certificates(unittest.TestCase):
    def test_signal_during_spawn_registers_child_before_cleanup(self):
        loader = importlib.machinery.SourceFileLoader('mailbend_demo_spawn', str(DEMO))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='mailbend-demo-spawn-') as work:
            demo = module.Demo(work)
            original = subprocess.Popen
            children = []
            def interrupted_spawn(*args, **kwargs):
                proc = original(*args, **kwargs)
                children.append(proc)
                # This is inside Popen from Demo.start's point of view: the
                # returned child has not yet been registered by the caller.
                os.kill(os.getpid(), signal.SIGTERM)
                return proc
            previous = signal.signal(signal.SIGTERM, demo.interrupted)
            try:
                with mock.patch.object(module.subprocess, 'Popen', interrupted_spawn):
                    proc = demo.start(['/bin/sleep', '300'])
                self.assertTrue(demo.stopping)
                self.assertIn(proc, demo.children)
                demo.cleanup()
                self.assertFalse(live(proc.pid))
            finally:
                signal.signal(signal.SIGTERM, previous)
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.wait()

    def test_startup_protocol_failures_are_bounded_and_cleaned(self):
        loader = importlib.machinery.SourceFileLoader('mailbend_demo_startup', str(DEMO))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        for program in ('print("READY imap=0 smtp=70000", flush=True)',
                        'print("garbage", flush=True)', 'pass',
                        'import time; time.sleep(300)'):
            with self.subTest(program=program), tempfile.TemporaryDirectory() as work:
                demo = module.Demo(work)
                real_start = demo.start
                children = []
                def start(*_args, **kwargs):
                    proc = real_start([sys.executable, '-I', '-c', program], **kwargs)
                    children.append(proc)
                    return proc
                try:
                    with mock.patch.object(demo, 'certificates'), \
                         mock.patch.object(demo, 'start', start), \
                         mock.patch.object(module, 'START_TIMEOUT', .2):
                        with self.assertRaises(module.DemoError):
                            demo.server()
                finally:
                    demo.cleanup()
                    for proc in children:
                        if proc.stdout:
                            proc.stdout.close()
                        self.assertFalse(live(proc.pid))

    def test_demo_certificates_are_minimal_and_verified(self):
        with tempfile.TemporaryDirectory(prefix='mailbend-demo-certs-') as work:
            subprocess.run(['/bin/sh', str(ROOT / 'tests/gen-test-certs.sh'), work, '--demo'],
                           check=True, timeout=30)
            self.assertEqual(set(path.name for path in Path(work).iterdir()),
                             {'ca.pem', 'server.pem', 'server-key.pem'})
            subprocess.run(['openssl', 'verify', '-CAfile', work + '/ca.pem',
                            '-verify_hostname', 'localhost', work + '/server.pem'],
                           check=True, capture_output=True, timeout=5)
            rejected = subprocess.run(['openssl', 'verify', '-CAfile', work + '/ca.pem',
                                       '-verify_hostname', 'other.example.test', work + '/server.pem'],
                                      capture_output=True, timeout=5)
            self.assertNotEqual(rejected.returncode, 0)

    def test_expired_fixture_has_valid_order_but_is_expired(self):
        with tempfile.TemporaryDirectory(prefix='mailbend-expired-certs-') as work:
            subprocess.run(['/bin/sh', str(ROOT / 'tests/gen-test-certs.sh'), work],
                           check=True, timeout=30)
            dates = subprocess.run(['openssl', 'x509', '-in', work + '/expired.pem',
                                    '-noout', '-dates'], check=True, text=True,
                                   capture_output=True, timeout=5).stdout
            self.assertIn('notBefore=Jan  1 00:00:00 2000 GMT', dates)
            self.assertIn('notAfter=Jan  2 00:00:00 2000 GMT', dates)
            verified = subprocess.run(['openssl', 'verify', '-CAfile', work + '/ca.pem',
                                       '-verify_hostname', 'localhost', work + '/expired.pem'],
                                      text=True, capture_output=True, timeout=5)
            self.assertNotEqual(verified.returncode, 0)
            self.assertIn('certificate has expired', verified.stderr)


class Contract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mailbend demo tests ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for relative in ('scripts/mailbend-demo', 'tests/fake_mail_server.py',
                         'tests/gen-test-certs.sh', 'tests/fixtures/demo-mailbox.json'):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        (self.root / 'bin').mkdir()
        for name in ('core', 'tls', 'attach', 'stdio', 'typesafe'):
            (self.root / f'bin/mailbend-{name}').write_text('#!/bin/sh\nexit 0\n')
            (self.root / f'bin/mailbend-{name}').chmod(0o700)
        launcher = self.root / 'scripts/mailbend'
        launcher.write_text(f'#!{sys.executable} -I\n'
                           'import os, sys, json, subprocess\n'
                           'child = subprocess.Popen(["/bin/sleep", "300"])\n'
                           'print(json.dumps({"env": dict(os.environ), "pid": os.getpid(), '
                           '"child": child.pid, "args": sys.argv[1:]}), flush=True)\n'
                           'sys.stdin.buffer.read()\n')
        launcher.chmod(0o700)
        # Inspect environments in real certificate/server child processes.
        cert = self.root / 'tests/gen-test-certs.sh'
        cert.write_text(cert.read_text().replace('set -eu',
            'set -eu\nenv > "$(dirname "$0")/cert.env"', 1))
        server = self.root / 'tests/fake_mail_server.py'
        marker = '\nfrom datetime import datetime, timezone'
        server.write_text(server.read_text().replace(marker,
            '\nwith open(os.path.join(os.path.dirname(__file__), "server.env"), "w") as out:\n'
            '    json.dump(dict(os.environ), out)\n'
            'with open(os.path.join(os.path.dirname(__file__), "server.pid"), "w") as out:\n'
            '    out.write(str(os.getpid()))\n' + marker))

    def start(self):
        demo = RunningDemo(self.root)
        self.addCleanup(demo.close)
        return demo

    def test_environment_isolation_and_owner_shutdown_with_idle_client(self):
        demo = self.start()
        self.assertEqual(demo.work.stat().st_mode & 0o777, 0o700)
        self.assertNotIn(SENTINEL, json.dumps(demo.config))
        owner_env = Path(f'/proc/{demo.proc.pid}/environ').read_bytes()
        cert_env = (self.root / 'tests/cert.env').read_text()
        server_env = (self.root / 'tests/server.env').read_text()
        for text in (owner_env.decode(), cert_env, server_env):
            for value in (SENTINEL, '/private', 'private@example.test',
                          'remote.example.test', '/not-the-helper'):
                self.assertNotIn(value, text)
            self.assertNotIn('MAILBEND_', text)
        proc, lines = demo.connect()
        snapshot = lines.json()
        env = snapshot['env']
        for key in POISON:
            if key in env:
                self.assertNotEqual(env[key], POISON[key], key)
        self.assertEqual(env['MAILBEND_TYPESAFE'], '0')
        self.assertEqual(env['MAILBEND_ALLOWED_RECIPIENTS'], 'friend@example.com')
        for protocol in ('IMAP', 'SMTP'):
            self.assertEqual(env[f'MAILBEND_{protocol}_HOST'], 'localhost')
            self.assertEqual(env[f'MAILBEND_{protocol}_CONNECT_IP'], '127.0.0.1')
        self.assertEqual(env['MAILBEND_CA_FILE'], str(demo.work / 'certs/ca.pem'))
        self.assertEqual(snapshot['args'], ['mcp'])
        server_pid = int((self.root / 'tests/server.pid').read_text())
        ports = [int(env[f'MAILBEND_{protocol}_PORT']) for protocol in ('IMAP', 'SMTP')]
        demo.close()
        self.assertFalse(demo.work.exists())
        for pid in (server_pid, snapshot['pid'], snapshot['child']):
            until(lambda: not live(pid))
        for port in ports:
            with socket.socket() as sock:
                self.assertNotEqual(sock.connect_ex(('127.0.0.1', port)), 0)
        self.assertEqual(proc.returncode, 0)
        stale = subprocess.run([demo.config['command'], *demo.config['args']],
                               capture_output=True, timeout=5)
        self.assertEqual(stale.returncode, 2)

    def test_refuses_external_hosts_missing_build_and_unknown_commands(self):
        for host in ('mail.example.test', '0.0.0.0', '192.0.2.1', 'localhost.example.test', '::1'):
            run = subprocess.run([str(self.root / 'scripts/mailbend-demo'), '--host', host],
                                 capture_output=True, timeout=5)
            self.assertNotEqual(run.returncode, 0)
        (self.root / 'bin/mailbend-tls').unlink()
        run = subprocess.run([str(self.root / 'scripts/mailbend-demo')], capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 2)
        self.assertIn(b'build this checkout', run.stderr)
        self.assertFalse((self.root / 'tests/server.pid').exists())

    def test_rejects_untrusted_session_and_malformed_socket_headers(self):
        demo = self.start()
        for header in (b'{}\n', b'["mcp", "unexpected"]\n', b'["/bin/sh"]\n', b'["mcp", 1]\n', b'["mcp\\u0000"]\n',
                       b'[' + b' ' * 65535):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(5)
                client.connect(str(demo.work / 'client.sock'))
                client.sendall(header)
                self.assertEqual(client.recv(1), b'')
        demo.work.chmod(0o755)
        run = subprocess.run([demo.config['command'], *demo.config['args']],
                             capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 2)
        demo.work.chmod(0o700)
        link = self.root / 'session-link'
        link.symlink_to(demo.work, target_is_directory=True)
        run = subprocess.run([demo.config['command'], '--session', str(link), '--', 'mcp'],
                             capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 2)

    def test_two_sessions_and_sigint_cleanup(self):
        one, two = self.start(), self.start()
        self.assertNotEqual(one.work, two.work)
        proc, lines = two.connect()
        snapshot = lines.json()
        one.close(signal.SIGINT)
        self.assertFalse(one.work.exists())
        self.assertTrue(two.work.exists())
        self.assertTrue(live(snapshot['pid']))
        two.close()

    def test_shutdown_during_certificate_creation_cleans_descendants(self):
        cert = self.root / 'tests/gen-test-certs.sh'
        cert.write_text('#!/bin/sh\n'
                        'printf "%s\\n" "$1" > "$(dirname "$0")/work.path"\n'
                        'sleep 300 &\n'
                        'printf "%s\\n" "$!" > "$(dirname "$0")/openssl.pid"\n'
                        'wait\n')
        proc = subprocess.Popen([str(self.root / 'scripts/mailbend-demo')],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            until(lambda: (self.root / 'tests/openssl.pid').exists())
            child = int((self.root / 'tests/openssl.pid').read_text())
            work = Path((self.root / 'tests/work.path').read_text().strip()).parent
            proc.terminate()
            proc.communicate(timeout=10)
            until(lambda: not live(child))
            self.assertFalse(work.exists())
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait()

    def test_server_exit_stops_clients_and_removes_directory(self):
        demo = self.start()
        proc, lines = demo.connect()
        snapshot = lines.json()
        server_pid = int((self.root / 'tests/server.pid').read_text())
        os.kill(server_pid, signal.SIGTERM)
        demo.proc.wait(timeout=10)
        self.assertEqual(demo.proc.returncode, 2)
        until(lambda: not live(snapshot['pid']))
        self.assertFalse(demo.work.exists())


class Integration(unittest.TestCase):
    def setUp(self):
        self.demo = RunningDemo()
        self.addCleanup(self.demo.close)
        self.proc, self.lines = self.demo.connect()
        self.id = 0
        result = self.rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                                        'clientInfo': {'name': 'demo-test', 'version': '1'}})
        self.assertIn('protocolVersion', result)
        self.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.proc.stdin.flush()

    def rpc(self, method, params):
        self.id += 1
        self.proc.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': self.id,
                                         'method': method, 'params': params}).encode() + b'\n')
        self.proc.stdin.flush()
        reply = self.lines.json()
        self.assertEqual(reply['id'], self.id)
        self.assertNotIn('error', reply)
        self.assertNotIn(SENTINEL, json.dumps(reply))
        return reply['result']

    def call(self, name, **args):
        result = self.rpc('tools/call', {'name': name, 'arguments': args})
        if 'structuredContent' in result:
            return result['structuredContent']
        return json.loads(result['content'][0]['text'])

    def state(self):
        return json.loads((self.demo.work / 'state.json').read_text())

    def test_real_printed_mcp_configuration_reads_trashes_and_sends(self):
        tools = self.rpc('tools/list', {})
        self.assertNotIn('mail_classify', [tool['name'] for tool in tools['tools']])
        self.assertNotIn('mail_triage', [tool['name'] for tool in tools['tools']])
        searched = self.call('mail_search')
        self.assertNotIn('error', searched)
        self.assertIn('Demo invoice', json.dumps(searched))
        read = self.call('mail_get', uid=3, uidvalidity=1700000001)
        self.assertIn('PROMPT INJECTION DEMO', json.dumps(read))
        self.assertNotIn('error', read)
        before = self.state()
        self.assertTrue(all(not message['flags'] for message in before['mailboxes']['INBOX']['messages']))
        trash = self.call('mail_trash', uids=[1], uidvalidity=1700000001)
        self.assertNotIn('error', trash)
        state = self.state()
        self.assertEqual(len(state['mailboxes']['INBOX']['messages']), 2)
        self.assertEqual(len(state['mailboxes']['Trash']['messages']), 1)
        denied = self.call('mail_send', to=['collector@example.net'], subject='No', body='No')
        self.assertIn('error', denied)
        sent = self.call('mail_send', to=['friend@example.com'], subject='Demo hello', body='Synthetic mail')
        self.assertNotIn('error', sent)
        self.assertTrue(sent.get('ok'), sent)
        state = self.state()
        self.assertEqual(len(state['sent']), 1)
        self.assertIn('Demo hello', json.dumps(state['sent']))
        log = (self.demo.work / 'commands.jsonl').read_text()
        self.assertNotIn('collector@example.net', log)

    def test_untrusted_certificate_still_fails(self):
        # Replace only the trusted CA with a different test certificate. The
        # production helper must reject the already-running server certificate.
        ca = self.demo.work / 'certs/ca.pem'
        original = ca.read_bytes()
        other = self.demo.work / 'other-ca.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc',
                        '-keyout', str(self.demo.work / 'other-key.pem'), '-out', str(other),
                        '-days', '1', '-subj', '/CN=Unrelated demo test CA'],
                       check=True, capture_output=True, timeout=15)
        ca.write_bytes(other.read_bytes())
        result = self.call('mail_probe')
        self.assertIn('error', result)
        ca.write_bytes(original)
        self.assertNotIn('error', self.call('mail_probe'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--contract-only', action='store_true')
    args, remaining = parser.parse_known_args()
    suite = unittest.TestLoader().loadTestsFromTestCase(Certificates)
    suite.addTests(unittest.TestLoader().loadTestsFromTestCase(Contract))
    if not args.contract_only:
        suite.addTests(unittest.TestLoader().loadTestsFromTestCase(Integration))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
