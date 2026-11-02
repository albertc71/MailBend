#!/usr/bin/env python3
"""The optional fake-server audit captures complete rejected wires, without sockets."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

import fake_mail_server as fake


def interrupted_run_audit():
    spec = importlib.util.spec_from_file_location('capture_e2e', Path(__file__).with_name('test-e2e.py'))
    e2e = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = e2e
    spec.loader.exec_module(e2e)
    for original_error, audit_error in [(RuntimeError('original'), None),
                                        (RuntimeError('original'), ValueError('audit')),
                                        (None, ValueError('audit'))]:
        e2e.results.clear()
        with patch.object(e2e.subprocess, 'run'), patch.object(e2e, 'run_all', side_effect=original_error), \
             patch.object(e2e.mime_oracle, 'check_captured', side_effect=audit_error) as audit, \
             contextlib.redirect_stdout(io.StringIO()):
            try:
                e2e.main()
            except RuntimeError as error:
                assert original_error is error
            except SystemExit as error:
                assert original_error is None and error.code == 1
            else:
                raise AssertionError('run or audit failure was hidden')
        audit.assert_called_once_with(e2e.composed_messages, e2e.check)
        assert any(not ok for _, ok in e2e.results) == bool(audit_error)


def main():
    raw = 'Subject: synthetic\r\n\r\n..dot\r\n'
    with tempfile.TemporaryDirectory(prefix='mime-capture-') as directory:
        root = Path(directory)
        logger = fake.Logger(str(root / 'commands.jsonl'), str(root / 'composed.jsonl'))
        imap = fake.IMAPSession.__new__(fake.IMAPSession)
        imap.logger = logger
        imap.state = SimpleNamespace(seen={}, reject={'APPEND'})
        replies = []
        imap.send = replies.append
        imap.run_command([b'a1', b'APPEND', b'Drafts', raw.encode('latin-1')])
        assert replies == ['a1 NO refused by the test server\r\n']
        smtp = fake.SMTPSession.__new__(fake.SMTPSession)
        smtp.logger = logger
        smtp.authenticated = True
        smtp.mail_from = 'sender@example.invalid'
        smtp.rcpt_to = ['final-reject@example.com']
        wire = iter([b'Subject: synthetic\r\n', b'\r\n', b'...dot\r\n', b'.\r\n'])
        smtp.conn = SimpleNamespace(readline=lambda: next(wire))
        smtp.send = replies.append
        smtp.cmd_data()
        assert replies[-1].startswith('554 ')
        records = [json.loads(line) for line in (root / 'composed.jsonl').read_text().splitlines()]
        assert records == [{'protocol': 'append', 'raw': raw}, {'protocol': 'smtp', 'raw': raw}]
        plain = fake.Logger(str(root / 'plain.jsonl'))
        before = {p.name: p.read_bytes() for p in root.iterdir()}
        assert plain.composed is None
        plain.composition('smtp', raw)
        assert {p.name: p.read_bytes() for p in root.iterdir()} == before
    interrupted_run_audit()
    print('MIME capture: rejected wires, dot unstuffing, optional audit and interrupted-run controls checked')


if __name__ == '__main__':
    main()
