"""Actual helper LOGIN sequences over verified, synthetic loopback TLS.

Invoked by test-transport.sh with its helper, generated certificates and fixture.
Each helper retains the established 5-second timeout and 10-second outer bound.
"""
import argparse
import base64
import json
import pathlib
import select
import socket
import ssl
import subprocess
import sys
import threading
import time


class TLSWire:
    """MemoryBIO keeps TLS record creation separate from socket fragmentation."""

    def __init__(self, sock, context):
        self.sock = sock
        self.incoming = ssl.MemoryBIO()
        self.outgoing = ssl.MemoryBIO()
        self.tls = context.wrap_bio(self.incoming, self.outgoing, server_side=True)
        self.buffer = b''
        self.closed = False
        while True:
            try:
                self.tls.do_handshake()
                self.flush()
                break
            except ssl.SSLWantReadError:
                self.receive()

    def flush(self):
        while self.outgoing.pending:
            self.sock.sendall(self.outgoing.read())

    def receive(self):
        self.flush()
        block = self.sock.recv(16384)
        if not block:
            raise EOFError
        self.incoming.write(block)

    def line(self):
        while b'\n' not in self.buffer:
            try:
                block = self.tls.read(16384)
                if not block:
                    raise EOFError
                self.buffer += block
            except ssl.SSLWantReadError:
                self.receive()
        result, self.buffer = self.buffer.split(b'\n', 1)
        return result + b'\n'

    def observe(self, seconds, records, stop=None):
        deadline = time.monotonic() + seconds
        while True:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                records.append(command_name(line + b'\n'))
                if len(records) > 64:
                    raise RuntimeError('command observation limit')
            if len(self.buffer) > 65536:
                raise RuntimeError('partial command observation limit')
            interrupted = stop is not None and stop.is_set()
            left = deadline - time.monotonic()
            if self.closed or interrupted or left <= 0:
                return self.closed or interrupted
            try:
                block = self.tls.read(16384)
                if block:
                    self.buffer += block
                else:
                    self.closed = True
            except ssl.SSLWantReadError:
                ready, _, _ = select.select([self.sock], [], [], min(left, 0.05))
                if ready:
                    try:
                        block = self.sock.recv(16384, socket.MSG_DONTWAIT)
                    except BlockingIOError:
                        continue
                    except ConnectionResetError:
                        self.closed = True
                        continue
                    if block:
                        self.incoming.write(block)
                    else:
                        self.closed = True
            except (ssl.SSLZeroReturnError, ssl.SSLEOFError):
                self.closed = True

    def encoded(self, text):
        assert self.outgoing.pending == 0
        assert self.tls.write(text) == len(text)
        return self.outgoing.read()

    def send(self, text):
        self.sock.sendall(self.encoded(text))


def command_name(line):
    if line.startswith(b'L LOGIN '):
        return 'LOGIN'
    if line == b'a1 NOOP\r\n':
        return 'NOOP'
    if line == b'Z LOGOUT\r\n':
        return 'LOGOUT'
    return 'unexpected'


def scenario(wire, name, hostile, stop, records, facts):
    bye = b'* BYE [UNAVAILABLE]' + hostile + b'\r\n'
    wire.send(bye)
    if name.startswith('delayed-'):
        reply = {
            'delayed-credentials': b'NO [AUTHENTICATIONFAILED]',
            'delayed-bare-no': b'NO',
            'delayed-temporary': b'NO [UNAVAILABLE]',
            'delayed-bad': b'BAD',
        }[name]
        if not stop.wait(0.2):
            wire.send(b'L ' + reply + hostile + b'\r\n')
    elif name in ('conflicting-close', 'conflicting-tagged'):
        wire.send(b'* BYE [LIMIT]' + hostile + b'\r\n')
        if name == 'conflicting-close':
            return
        wire.send(b'L NO [AUTHENTICATIONFAILED]' + hostile + b'\r\n')
    elif name == 'silence':
        wire.observe(9, records, stop)
        return
    elif name in ('stream-lines', 'stream-byes', 'drip-line', 'drip-literal', 'zero-literals'):
        if name == 'drip-line':
            wire.send(b'L NO ')
        if name == 'drip-literal':
            wire.send(b'* DATA {4096}\r\n')
        payload = {
            'stream-lines': b'* OK' + hostile + b'\r\n',
            'stream-byes': b'* BYE [LIMIT]' + hostile + b'\r\n',
            'drip-line': b'x',
            'drip-literal': b'x',
            'zero-literals': b'* DATA {0}\r\n',
        }[name]
        while not wire.observe(0.1, records, stop):
            wire.send(payload)
        return
    elif name == 'fragmented-record':
        record = wire.encoded(b'L NO [AUTHENTICATIONFAILED]' + hostile + b'\r\n')
        assert record[0] == 23 and len(record) == 5 + int.from_bytes(record[3:5], 'big')
        assert len(record) > 100
        facts.append('one-fragmented-TLS-record')
        for byte in record:
            if wire.observe(0.1, records, stop):
                return
            wire.sock.sendall(bytes([byte]))
    elif name in ('restore-after-expiry', 'restore-timeout-values'):
        if name == 'restore-after-expiry':
            if stop.wait(2):
                return
            delay = 3.5
        else:
            if stop.wait(4):
                return
            wire.send(b'* OK' + hostile + b'\r\n')
            if stop.wait(0.25):
                return
            delay = 2
        wire.send(b'L OK' + hostile + b'\r\n')
        records.append(command_name(wire.line()))
        if stop.wait(delay):
            return
        wire.send(b'a1 OK completed\r\n')
        records.append(command_name(wire.line()))
        wire.send(b'* BYE goodbye\r\nZ OK completed\r\n')
        return
    else:
        raise AssertionError('unknown synthetic scenario')
    while True:
        records.append(command_name(wire.line()))


def run_case(helper, certs, fixture, name, expected, reason, mode):
    password = fixture['password'].encode()
    hostile = b' private-server-marker ' + password + b' mailbend-auth: credentials'
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certs / 'ip-address.pem', certs / 'ip-address-key.pem')
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    listener.settimeout(5)
    port = listener.getsockname()[1]
    stop = threading.Event()
    records, facts, failures, sockets = [], [], [], []

    def serve():
        try:
            raw, _ = listener.accept()
            sockets.append(raw)
            raw.settimeout(5)
            raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with raw:
                wire = TLSWire(raw, context)
                wire.send(b'* OK synthetic sequence server\r\n')
                records.append(command_name(wire.line()))
                try:
                    scenario(wire, name, hostile, stop, records, facts)
                finally:
                    try:
                        wire.observe(0.25, records)
                    finally:
                        if wire.buffer:
                            records.append('partial-application')
                            wire.buffer = b''
        except (EOFError, ConnectionResetError, BrokenPipeError, ssl.SSLEOFError):
            pass
        except OSError as error:
            failures.append(type(error).__name__)
        except Exception as error:
            failures.append(type(error).__name__)

    server = threading.Thread(target=serve)
    server.start()
    environment = {
        'PATH': '/usr/bin:/bin',
        'LANG': 'C.UTF-8',
        'MAILBEND_EMAIL': fixture['user'],
        'MAILBEND_APP_PASSWORD': fixture['password'],
        'MAILBEND_IMAP_HOST': '127.0.0.1',
        'MAILBEND_IMAP_PORT': str(port),
        'MAILBEND_CA_FILE': str(certs / 'ca.pem'),
        'MAILBEND_TIMEOUT_MS': '5000',
    }
    outer_timeout = False
    result = None
    try:
        result = subprocess.run(
            [str(helper), mode], env=environment, capture_output=True,
            input=b'a1 NOOP\r\n' if mode == 'imap' else b'', timeout=10)
    except subprocess.TimeoutExpired:
        outer_timeout = True
    finally:
        stop.set()
        cleanup_deadline = time.monotonic() + 5
        server.join(1)
        if server.is_alive():
            if sockets:
                failures.append('observation-incomplete')
            for sock in sockets:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            server.join(max(0, cleanup_deadline - time.monotonic()))
        listener.setblocking(False)
        while True:
            try:
                extra, _ = listener.accept()
            except BlockingIOError:
                break
            with extra:
                records.append('reconnect')
        listener.close()
    if server.is_alive():
        raise RuntimeError('synthetic server did not stop')
    if outer_timeout:
        print(f'FAIL {name} {mode}: outer deadline, not a product timeout')
        return False
    content = result.stdout + result.stderr
    leaked = any(value in content for value in (
        password, b'private-server-marker', base64.b64encode(password),
        base64.b64encode(b'\0' + fixture['user'].encode() + b'\0' + password)))
    if mode == 'imap':
        tokens = [line for line in result.stderr.splitlines() if line.startswith(b'mailbend-auth: ')]
        wanted = [] if reason is None else [b'mailbend-auth: ' + reason.encode()]
        classified = result.returncode == expected and tokens == wanted
        if expected == 6 and reason is None:
            classified = classified and b'read from server timed out' in result.stderr
    else:
        authentication = [line for line in result.stdout.splitlines()
                          if line.startswith(b'authentication ')]
        classified = (result.returncode == 0 and not result.stderr
                      and authentication == [b'authentication ' + (reason or 'failed').encode()])
    expected_commands = ['LOGIN', 'NOOP', 'LOGOUT'] if expected == 0 else ['LOGIN']
    record_ok = name != 'fragmented-record' or facts == ['one-fragmented-TLS-record']
    passed = classified and not leaked and records == expected_commands and not failures and record_ok
    print(f'{"PASS" if passed else "FAIL"} {name} {mode}: '
          f'exit={result.returncode} classification={classified} redacted={not leaked} '
          f'commands={records} fixture_errors={failures} record={record_ok}')
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('helper', type=pathlib.Path)
    parser.add_argument('certs', type=pathlib.Path)
    parser.add_argument('fixture', type=pathlib.Path)
    parser.add_argument('--case', action='append', default=[])
    parser.add_argument('--mode', choices=('imap', 'diagnose-imap'))
    args = parser.parse_args()
    helper, certs = args.helper, args.certs
    fixture = json.loads(args.fixture.read_text())
    cases = [
        ('delayed-credentials', 4, 'credentials'),
        ('delayed-bare-no', 4, 'credentials'),
        ('delayed-temporary', 4, 'temporary'),
        ('delayed-bad', 4, 'unknown'),
        ('conflicting-close', 6, 'temporary'),
        ('conflicting-tagged', 4, 'credentials'),
        ('silence', 6, None),
        ('stream-lines', 6, None),
        ('stream-byes', 6, None),
        ('drip-line', 6, None),
        ('fragmented-record', 6, None),
        ('drip-literal', 6, None),
        ('zero-literals', 6, None),
        ('restore-after-expiry', 0, None),
        ('restore-timeout-values', 0, None),
    ]
    unknown = set(args.case) - {name for name, _, _ in cases}
    if unknown:
        parser.error('unknown sequence case')
    selected = [case for case in cases if not args.case or case[0] in args.case]
    if args.mode == 'diagnose-imap' and any(expected == 0 for _, expected, _ in selected):
        parser.error('successful command controls require imap mode')
    passed = failed = 0
    for name, expected, reason in selected:
        modes = (args.mode,) if args.mode else (
            ('imap',) if expected == 0 else ('imap', 'diagnose-imap'))
        for mode in modes:
            ok = run_case(helper, certs, fixture, name, expected, reason, mode)
            passed += ok
            failed += not ok
    print(f'auth sequences: {passed} passed, {failed} failed')
    return bool(failed)


if __name__ == '__main__':
    sys.exit(main())
