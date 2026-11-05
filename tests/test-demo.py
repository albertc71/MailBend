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
    def __init__(self, root=ROOT, env=None, ignore_sigchld=False):
        argv = [str(root / 'scripts/mailbend-demo')]
        if ignore_sigchld:
            argv = [sys.executable, '-I', '-c',
                    'import os, signal, sys; signal.signal(signal.SIGCHLD, signal.SIG_IGN); '
                    'os.execv(sys.argv[1], sys.argv[1:])', *argv]
        self.proc = subprocess.Popen(argv,
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


class ProcessLifetime(unittest.TestCase):
    def setUp(self):
        loader = importlib.machinery.SourceFileLoader('mailbend_demo_lifetime', str(DEMO))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.module = importlib.util.module_from_spec(spec)
        loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory(prefix='mailbend-demo-lifetime-')
        self.addCleanup(self.temp.cleanup)
        self.demo = self.module.Demo(self.temp.name)
        self.addCleanup(self.demo.cleanup)

    def start(self, program):
        proc = self.demo.start([sys.executable, '-I', '-c', program], stdout=subprocess.PIPE)
        self.addCleanup(proc.stdout.close)
        self.addCleanup(self.demo.stop, proc)
        return proc, Lines(proc.stdout)

    def test_exited_leader_stays_reserved_until_descendants_are_stopped(self):
        proc, lines = self.start(
            'import os, signal, time\n'
            'ready, writer = os.pipe()\n'
            'child = os.fork()\n'
            'if child == 0:\n'
            '    os.close(ready)\n'
            '    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
            '    os.write(writer, b"1")\n'
            '    os.close(writer)\n'
            '    time.sleep(300)\n'
            'else:\n'
            '    os.close(writer)\n'
            '    os.read(ready, 1)\n'
            '    print(child, flush=True)\n'
        )
        child = lines.json()
        until(lambda: self.demo.exited(proc))
        self.assertIsNone(proc.returncode)
        self.assertTrue(Path(f'/proc/{proc.pid}').exists())
        self.assertTrue(live(child))
        real_killpg = os.killpg
        calls = []
        def checked_killpg(pid, sig):
            self.assertEqual(pid, proc.pid)
            self.assertIsNone(proc.returncode, 'group signal after reap')
            self.assertTrue(Path(f'/proc/{pid}').exists(), 'leader no longer reserves PID')
            calls.append(sig)
            real_killpg(pid, sig)
        with mock.patch.object(self.module.os, 'killpg', checked_killpg):
            self.assertEqual(self.demo.stop(proc), 0)
            self.demo.stop(proc)
            self.demo.cleanup()
        self.assertEqual(calls, [signal.SIGTERM, signal.SIGKILL])
        self.assertNotIn(proc, self.demo.children)
        until(lambda: not live(child))

    def test_cleanup_and_client_exit_serialize_the_final_reap(self):
        proc, _ = self.start('pass')
        until(lambda: self.demo.exited(proc))
        reaping = threading.Event()
        release = threading.Event()
        contended = threading.Event()
        original_lock = self.demo.lock
        class ObservedLock:
            def __enter__(self):
                if not original_lock.acquire(blocking=False):
                    contended.set()  # A real failed acquisition, not thread entry.
                    original_lock.acquire()
            def __exit__(self, *_args):
                original_lock.release()
        self.demo.lock = ObservedLock()
        errors = []
        real_wait = proc.wait
        def delayed_wait(*args, **kwargs):
            reaping.set()
            if not release.wait(5):
                raise AssertionError('concurrent cleanup did not reach the reap')
            return real_wait(*args, **kwargs)
        def stop_client():
            try:
                self.demo.stop(proc)
            except Exception as error:
                errors.append(error)
        def cleanup_owner():
            try:
                self.demo.cleanup()
            except Exception as error:
                errors.append(error)
        with mock.patch.object(proc, 'wait', side_effect=delayed_wait) as wait_mock, \
             mock.patch.object(self.module.os, 'killpg', wraps=os.killpg) as kill_mock:
            client = threading.Thread(target=stop_client)
            owner = threading.Thread(target=cleanup_owner)
            client.start()
            try:
                self.assertTrue(reaping.wait(5))
                owner.start()
                self.assertTrue(contended.wait(5))
            finally:
                release.set()
                client.join(5)
                if owner.ident is not None:
                    owner.join(5)
            self.assertFalse(client.is_alive())
            self.assertFalse(owner.is_alive())
            self.assertEqual(errors, [])
            self.demo.stop(proc)
            self.demo.cleanup()
            self.assertEqual(wait_mock.call_count, 1)
            self.assertEqual(kill_mock.call_args_list,
                             [mock.call(proc.pid, signal.SIGTERM),
                              mock.call(proc.pid, signal.SIGKILL)])
        self.assertEqual(proc.returncode, 0)

    def test_grace_wait_does_not_block_other_children(self):
        proc, lines = self.start('import signal, time\n'
                                 'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                                 'print(1, flush=True)\n'
                                 'time.sleep(300)\n')
        self.assertEqual(lines.json(), 1)
        waiting = threading.Event()
        release = threading.Event()
        observed = threading.Event()
        errors = []
        def grace_sleep(_delay):
            waiting.set()
            if not release.wait(5):
                raise AssertionError('unrelated child blocked during grace wait')
        def stop():
            try:
                self.demo.stop(proc)
            except Exception as error:
                errors.append(error)
        def observe():
            try:
                other, _ = self.start('pass')
                self.demo.exited(other)
                observed.set()
            except Exception as error:
                errors.append(error)
        with mock.patch.object(self.module.time, 'sleep', grace_sleep), \
             mock.patch.object(self.module, 'STOP_TIMEOUT', .05):
            stopper = threading.Thread(target=stop)
            observer = threading.Thread(target=observe)
            stopper.start()
            try:
                self.assertTrue(waiting.wait(5))
                observer.start()
                self.assertTrue(observed.wait(2), 'shared lock held during grace wait')
                self.assertIsNone(proc.returncode)
                self.assertTrue(Path(f'/proc/{proc.pid}').exists())
            finally:
                release.set()
                stopper.join(5)
                if observer.ident is not None:
                    observer.join(5)
            self.assertFalse(stopper.is_alive())
            self.assertFalse(observer.is_alive())
            self.assertEqual(errors, [])

    def test_concurrent_stopper_waits_for_grace_owner(self):
        proc, lines = self.start('import signal, time\n'
                                 'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                                 'print(1, flush=True)\n'
                                 'time.sleep(300)\n')
        self.assertEqual(lines.json(), 1)
        grace = threading.Event()
        release = threading.Event()
        contended = threading.Event()
        finished = threading.Event()
        results = []
        errors = []
        def grace_sleep(_delay):
            grace.set()
            if not release.wait(5):
                raise AssertionError('second stopper did not wait for owner')
        def stop(second=False):
            try:
                results.append(self.demo.stop(proc))
            except Exception as error:
                errors.append(error)
            finally:
                if second:
                    finished.set()
        with mock.patch.object(self.module.time, 'sleep', grace_sleep), \
             mock.patch.object(self.module, 'STOP_TIMEOUT', .05), \
             mock.patch.object(self.module.os, 'killpg', wraps=os.killpg) as kill_mock, \
             mock.patch.object(proc, 'wait', wraps=proc.wait) as wait_mock:
            owner = threading.Thread(target=stop)
            other = threading.Thread(target=stop, args=(True,))
            owner.start()
            try:
                self.assertTrue(grace.wait(5))
                with self.demo.lock:
                    pending = self.demo.stop_owners[proc]
                real_wait = pending.wait
                def observed_wait(*args, **kwargs):
                    contended.set()
                    return real_wait(*args, **kwargs)
                with mock.patch.object(pending, 'wait', observed_wait):
                    other.start()
                    self.assertTrue(contended.wait(5))
                    self.assertFalse(finished.is_set())
                    self.assertEqual(kill_mock.call_args_list,
                                     [mock.call(proc.pid, signal.SIGTERM)])
                    wait_mock.assert_not_called()
                    release.set()
                    owner.join(5)
                    other.join(5)
            finally:
                release.set()
                owner.join(5)
                if other.ident is not None:
                    other.join(5)
            self.assertFalse(owner.is_alive())
            self.assertFalse(other.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(results, [-signal.SIGKILL, -signal.SIGKILL])
            self.assertEqual(wait_mock.call_count, 1)
            self.assertEqual(kill_mock.call_args_list,
                             [mock.call(proc.pid, signal.SIGTERM),
                              mock.call(proc.pid, signal.SIGKILL)])
            self.assertEqual(self.demo.stop_owners, {})

    def test_already_reaped_leader_is_never_signaled(self):
        for use_popen in (True, False):
            with self.subTest(use_popen=use_popen):
                proc, _ = self.start('pass')
                if use_popen:
                    proc.wait()
                else:
                    os.waitpid(proc.pid, 0)
                self.assertTrue(self.demo.exited(proc))
                with mock.patch.object(self.module.os, 'killpg') as kill_mock:
                    self.demo.stop(proc)
                    self.demo.cleanup()
                    kill_mock.assert_not_called()
                self.assertNotIn(proc, self.demo.children)
                self.demo.stopping = False

    def test_term_resistant_leader_is_killed_before_reap(self):
        proc, lines = self.start('import signal, time\n'
                                 'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                                 'print(1, flush=True)\n'
                                 'time.sleep(300)\n')
        self.assertEqual(lines.json(), 1)
        self.assertFalse(self.demo.exited(proc))
        with mock.patch.object(self.module, 'STOP_TIMEOUT', .05):
            self.assertEqual(self.demo.stop(proc), -signal.SIGKILL)
        self.assertFalse(live(proc.pid))


class Certificates(unittest.TestCase):
    def test_main_resets_inherited_sigchld_in_actual_child(self):
        # Exercise main without opening sockets or requiring compiled binaries.
        # The inspected process is a real child of Demo.start, not this test.
        with tempfile.TemporaryDirectory(prefix='mailbend-sigchld-') as root:
            binary = Path(root) / 'bin'
            binary.mkdir()
            for name in ('core', 'tls', 'attach', 'stdio', 'typesafe'):
                (binary / f'mailbend-{name}').symlink_to(sys.executable)
            probe = r'''
import os, runpy, signal, subprocess, sys
from pathlib import Path
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
module = runpy.run_path(sys.argv[1])
main = module['main']
main.__globals__['ROOT'] = Path(sys.argv[2])
def inspect(demo):
    proc = demo.start([sys.executable, '-I', '-c',
                       'print(open("/proc/self/status").read())'], stdout=subprocess.PIPE)
    with proc.stdout:
        print(proc.stdout.read().decode(), end='')
module['Demo'].run = inspect
sys.argv = [sys.argv[1]]
main()
'''
            run = subprocess.run([sys.executable, '-I', '-c', probe, str(DEMO), root],
                                 capture_output=True, text=True, check=True, timeout=10)
            ignored = next(line.split()[1] for line in run.stdout.splitlines()
                           if line.startswith('SigIgn:'))
            self.assertEqual(int(ignored, 16) & (1 << (signal.SIGCHLD - 1)), 0,
                             'demo child inherited SIGCHLD=SIG_IGN')

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
                           'status = open("/proc/self/status").read()\n'
                           'child = subprocess.Popen(["/bin/sleep", "300"])\n'
                           'print(json.dumps({"env": dict(os.environ), "pid": os.getpid(), '
                           '"child": child.pid, "status": status, "args": sys.argv[1:]}), flush=True)\n'
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
        help_run = subprocess.run([str(self.root / 'scripts/mailbend-demo'), '--help'],
                                  capture_output=True, check=True, timeout=5)
        self.assertNotIn(b'--host', help_run.stdout)
        for host in ('localhost', '127.0.0.1', 'mail.example.test', '0.0.0.0',
                     '192.0.2.1', 'localhost.example.test', '::1'):
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

    def test_inherited_sigchld_ignore_does_not_auto_reap_children(self):
        demo = RunningDemo(self.root, ignore_sigchld=True)
        self.addCleanup(demo.close)
        _, lines = demo.connect()
        snapshot = lines.json()
        ignored = next(line.split()[1] for line in snapshot['status'].splitlines()
                       if line.startswith('SigIgn:'))
        self.assertEqual(int(ignored, 16) & (1 << (signal.SIGCHLD - 1)), 0)
        demo.close()
        for pid in (snapshot['pid'], snapshot['child']):
            until(lambda: not live(pid))
        self.assertFalse(demo.work.exists())

    def test_client_exit_cleans_term_resistant_descendant(self):
        launcher = self.root / 'scripts/mailbend'
        launcher.write_text(f'#!{sys.executable} -I\n'
                           'import os, signal, sys, time\n'
                           'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                           'child = os.fork()\n'
                           'if child == 0:\n'
                           '    time.sleep(300)\n'
                           'else:\n'
                           '    print(child, flush=True)\n'
                           '    sys.stdin.buffer.read()\n')
        demo = self.start()
        proc, lines = demo.connect()
        child = lines.json()
        self.assertTrue(live(child))
        proc.stdin.close()
        proc.wait(timeout=5)
        until(lambda: not live(child))
        self.assertIsNone(demo.proc.poll())

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
    suite = unittest.TestLoader().loadTestsFromTestCase(ProcessLifetime)
    suite.addTests(unittest.TestLoader().loadTestsFromTestCase(Certificates))
    suite.addTests(unittest.TestLoader().loadTestsFromTestCase(Contract))
    if not args.contract_only:
        suite.addTests(unittest.TestLoader().loadTestsFromTestCase(Integration))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
