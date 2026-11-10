#!/usr/bin/env python3
"""Bounded synthetic SEARCH observation controls at the socket-write boundary."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile


class SocketWrites:
    def __init__(self, fail=False):
        self.fail = fail
        self.writes = []

    def recv(self, size):
        data, self.incoming = getattr(self, 'incoming', b''), b''
        return data

    def sendall(self, data):
        if self.fail:
            raise OSError('synthetic failed send')
        self.writes.append(data)


def check_source(path):
    spec = importlib.util.spec_from_file_location('search_fixture_control', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    failures = []

    def check(label, actual, expected):
        if actual != expected:
            failures.append(label)

    cases = [
        ('global_normal', 'normal', {}, [1, 3], False, False,
         [b'* SEARCH 1 3\r\n', b'A1 OK SEARCH completed\r\n'], [], ['14', '24']),
        ('global_duplicate', 'duplicate-uids', {}, [1, 3], False, False,
         [b'* SEARCH 1 1 3 3\r\n', b'A1 OK SEARCH completed\r\n'],
         ['* SEARCH 1 1 3 3\r\n'], ['18', '24']),
        ('mailbox_duplicate', 'normal', {'INBOX': 'duplicate-uids'}, [1, 3], False, False,
         [b'* SEARCH 1 1 3 3\r\n', b'A1 OK SEARCH completed\r\n'],
         ['* SEARCH 1 1 3 3\r\n'], ['18', '24']),
        ('mailbox_normal', 'duplicate-uids', {'INBOX': 'normal'}, [1, 3], False, False,
         [b'* SEARCH 1 3\r\n', b'A1 OK SEARCH completed\r\n'], [], ['14', '24']),
        ('other_mailbox', 'normal', {'Elsewhere': 'duplicate-uids'}, [1, 3], False, False,
         [b'* SEARCH 1 3\r\n', b'A1 OK SEARCH completed\r\n'], [], ['14', '24']),
        ('repeated_line', 'normal', {'INBOX': 'duplicate'}, [1, 3], False, False,
         [b'* SEARCH 1 3\r\n', b'* SEARCH 1 3\r\n', b'A1 OK SEARCH completed\r\n'], [],
         ['14', '14', '24']),
        ('malformed', 'normal', {'INBOX': 'malformed'}, [1, 3], False, False,
         [b'* SEARCH invalid\r\n', b'A1 OK SEARCH completed\r\n'], [], ['18', '24']),
        ('missing', 'normal', {'INBOX': 'missing'}, [1, 3], False, False,
         [b'A1 OK SEARCH completed\r\n'], [], ['24']),
        ('empty_duplicate', 'normal', {'INBOX': 'duplicate-uids'}, [], False, False,
         [b'* SEARCH\r\n', b'A1 OK SEARCH completed\r\n'], ['* SEARCH\r\n'], ['10', '24']),
        ('muted', 'normal', {'INBOX': 'duplicate-uids'}, [1, 3], True, False, [], [], []),
        ('send_failure', 'normal', {'INBOX': 'duplicate-uids'}, [1, 3], False, True, [], [], []),
    ]
    for name, global_mode, overrides, uids, muted, fail, wire, observed, sizes in cases:
        with tempfile.TemporaryDirectory(prefix='search-observation-') as temporary:
            folder = Path(temporary)
            fixture = {'user': 'fixture@example.test', 'password': 'synthetic-test-only',
                       'search_responses': overrides,
                       'mailboxes': {'INBOX': {'uidvalidity': 1, 'messages': [
                           {'uid': uid, 'flags': [], 'raw': 'Subject: Synthetic\r\n\r\n'}
                           for uid in uids]}}}
            state = module.State(fixture, str(folder / 'state.json'))
            state.search_response = global_mode
            state.measure_responses = True
            state.drop_unanswered = {'SEARCH'} if muted else set()
            logger = module.Logger(str(folder / 'log.jsonl'))
            sock = SocketWrites(fail)
            session = module.IMAPSession(sock, state, logger, set())
            session.authenticated = True
            session.mailbox = 'INBOX'
            closed = False
            try:
                session.run_command([b'A1', b'UID', b'SEARCH', b'ALL'])
            except module.ConnectionClosed:
                closed = True
            records = [json.loads(line) for line in (folder / 'log.jsonl').read_text().splitlines()]
            check(name + '.wire', sock.writes, wire)
            check(name + '.observation',
                  [row['line'] for row in records if row['proto'] == 'imap-search-response'], observed)
            check(name + '.measurement',
                  [row['line'] for row in records if row['proto'] == 'imap-bytes'], sizes)
            check(name + '.closed', closed, fail)
            check(name + '.global_unchanged', state.search_response, global_mode)
            check(name + '.protocols', sorted({row['proto'] for row in records}),
                  sorted((['imap-bytes'] if sizes else []) +
                         (['imap-search-response'] if observed else [])))

    with tempfile.TemporaryDirectory(prefix='search-command-log-') as temporary:
        folder = Path(temporary)
        fixture = {'user': 'fixture@example.test', 'password': 'synthetic-test-only',
                   'search_responses': {'INBOX': 'duplicate-uids', 'Other': 'normal'},
                   'mailboxes': {name: {'uidvalidity': 1, 'messages': [
                       {'uid': 1, 'flags': [], 'raw': 'Subject: Synthetic\r\n\r\n'}]}
                       for name in ('INBOX', 'Other')}}
        state = module.State(fixture, str(folder / 'state.json'))
        state.measure_responses = True
        logger = module.Logger(str(folder / 'log.jsonl'))
        sock = SocketWrites()
        sock.incoming = b'A1 UID SEARCH ALL\r\n'
        class ForwardingIMAP(module.IMAPSession):
            def send(self, text):
                super().send(text)

        session = ForwardingIMAP(sock, state, logger, set())
        session.authenticated = True
        session.mailbox = 'INBOX'
        session.run()
        session.mailbox = 'Other'
        session.run_command([b'A2', b'UID', b'SEARCH', b'ALL'])
        check('command_and_switch.wire', sock.writes, [
            b'* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] fake ready\r\n',
            b'* SEARCH 1 1\r\n', b'A1 OK SEARCH completed\r\n',
            b'* SEARCH 1\r\n', b'A2 OK SEARCH completed\r\n'])
        records = [json.loads(line) for line in (folder / 'log.jsonl').read_text().splitlines()]
        check('command_and_switch.logs', records, [
            {'proto': 'imap-bytes', 'line': '51'},
            {'proto': 'imap', 'line': 'A1 UID SEARCH ALL'},
            {'proto': 'imap-bytes', 'line': '14'},
            {'proto': 'imap-search-response', 'line': '* SEARCH 1 1\r\n'},
            {'proto': 'imap-bytes', 'line': '24'},
            {'proto': 'imap-bytes', 'line': '12'},
            {'proto': 'imap-bytes', 'line': '24'}])
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    args = parser.parse_args()
    target = args.root / 'tests/fake_mail_server.py'
    original = target.read_bytes()
    source = original.decode()
    phases = [
        ('old_global_gate', args.baseline.read_text(), [
            'mailbox_duplicate.observation', 'mailbox_duplicate.protocols',
            'mailbox_normal.observation', 'mailbox_normal.protocols',
            'empty_duplicate.observation', 'empty_duplicate.protocols', 'command_and_switch.logs']),
        ('candidate', source, []),
        ('without_doubling', source.replace(
            'matched = [uid for uid in matched for _ in range(2)]', 'matched = list(matched)'), [
            'global_duplicate.wire', 'global_duplicate.observation', 'global_duplicate.measurement',
            'mailbox_duplicate.wire', 'mailbox_duplicate.observation', 'mailbox_duplicate.measurement',
            'command_and_switch.wire', 'command_and_switch.logs']),
        ('observation_before_write', source.replace(
            "            self.send(response)\n"
            "            if mode == 'duplicate-uids' and not self.muted:\n"
            "                self.logger.log('imap-search-response', response)\n",
            "            if mode == 'duplicate-uids' and not self.muted:\n"
            "                self.logger.log('imap-search-response', response)\n"
            "            self.send(response)\n"), [
            'send_failure.observation', 'send_failure.protocols', 'command_and_switch.logs']),
        ('restored', source, []),
    ]
    assert source.count('matched = [uid for uid in matched for _ in range(2)]') == 1
    assert phases[2][1] != source and phases[3][1] != source
    print('candidate fixture sha256=' + hashlib.sha256(original).hexdigest(), flush=True)
    try:
        for name, content, expected in phases:
            target.write_text(content)
            failures = check_source(target)
            print(json.dumps({'phase': name, 'cases': 12, 'failed': failures}), flush=True)
            assert failures == expected, (name, failures, expected)
    finally:
        target.write_bytes(original)
    assert target.read_bytes() == original
    print('PASS: resolved-mode observation, independent wire controls, failed-send control, restoration.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
