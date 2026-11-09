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
        for audited in ('check_captured', 'check_untransmitted'):
            e2e.results.clear()
            e2e.composition_outcomes.clear()
            e2e.composition_outcomes.update({'dry run, replayed': 1, 'refusal, replayed': 1})
            with patch.object(e2e.subprocess, 'run'), patch.object(e2e, 'run_all', side_effect=original_error), \
                 patch.object(e2e.mime_oracle, 'check_captured',
                              side_effect=audit_error if audited == 'check_captured' else None) as captured, \
                 patch.object(e2e.mime_oracle, 'check_untransmitted',
                              side_effect=audit_error if audited == 'check_untransmitted' else None) as replayed, \
                 contextlib.redirect_stdout(io.StringIO()):
                try:
                    e2e.main()
                except RuntimeError as error:
                    assert original_error is error
                except SystemExit as error:
                    assert original_error is None and error.code == 1
                else:
                    raise AssertionError('run or audit failure was hidden')
            captured.assert_called_once_with(e2e.composed_messages, e2e.check)
            replayed.assert_called_once_with(e2e.untransmitted_messages, e2e.check)
            assert any(not ok for _, ok in e2e.results) == bool(audit_error)
    return e2e


def untransmitted_classification(e2e):
    """A dry run or refusal whose replay cannot reach the parser fails the run."""
    date = 'Date: Mon, 9 Nov 2026 10:00:00 +0000\r\n'
    wire = date + 'Subject: replayed\r\n\r\nbody\r\n'
    size = len(wire.encode('latin-1'))
    smtp = [{'protocol': 'smtp', 'raw': wire}]
    preview = {'dry_run': True, 'smtp': {'data': f'<{size} bytes>'}}
    refusal = {'error': 'refused; nothing was sent'}
    cases = [
        ('dry run replayed', 'mail_send', preview, (0, {'sent': True}, smtp), True, 'dry run, replayed'),
        ('refusal replayed', 'mail_send', refusal, (0, {'sent': True}, smtp), True, 'refusal, replayed'),
        ('input refusal', 'mail_send', refusal, (1, refusal, []), True, 'refused before composing'),
        ('preview size differs', 'mail_send', {'dry_run': True, 'smtp': {'data': f'<{size + 5} bytes>'}},
         (0, {'sent': True}, smtp), False, 'dry run, replayed'),
        ('dry run not replayed', 'mail_send', preview, (1, {'error': 'x'}, []), False, 'unaudited'),
        ('changed refusal', 'mail_send', refusal, (1, {'error': 'other'}, []), False, 'unaudited'),
        ('wrong protocol', 'mail_save_draft', refusal, (0, {'uid': 1}, smtp), False, 'unaudited'),
        ('extra wire', 'mail_send', refusal, (0, {'sent': True}, smtp + smtp), False, 'unaudited'),
    ]
    for label, name, out, replay, passes, outcome in cases:
        e2e.results.clear()
        e2e.composition_outcomes.clear()
        e2e.untransmitted_messages.clear()
        with patch.object(e2e, 'replay_twin', return_value=replay), contextlib.redirect_stdout(io.StringIO()):
            e2e.audit_composition(None, name, {'to': 'a@example.com'}, 0 if out.get('dry_run') else 1, out, {}, 0)
        assert all(ok for _, ok in e2e.results) == passes, label
        assert e2e.composition_outcomes == {outcome: 1}, (label, e2e.composition_outcomes)
        assert bool(e2e.untransmitted_messages) == (outcome in {'dry run, replayed', 'refusal, replayed'}), label
    with patch.object(e2e, 'replay_twin') as replay:
        e2e.composition_outcomes.clear()
        e2e.audit_composition(None, 'mail_send', {}, 0, {'sent': True}, {}, 0)
        e2e.audit_composition(None, 'mail_get', {}, 1, {'error': 'x'}, {}, 0)
        e2e.audit_composition(None, 'mail_send', None, 1, {'error': 'x'}, {}, 0)
    replay.assert_not_called()
    assert e2e.composition_outcomes == {'transmitted, received-wire audit': 1}
    with tempfile.TemporaryDirectory(prefix='mime-received-') as directory:
        server = SimpleNamespace(composed=str(Path(directory) / 'composed.jsonl'))
        Path(server.composed).write_text(json.dumps({'protocol': 'append', 'raw': wire}) + '\n'
                                         + json.dumps({'protocol': 'smtp', 'raw': wire}) + '\n')
        e2e.composition_outcomes.clear()
        with patch.object(e2e, 'replay_twin') as replay:
            e2e.audit_composition(server, 'mail_send', {}, 1, refusal, {}, 0, 1)
        replay.assert_not_called()
        assert e2e.composition_outcomes == {'refused after transmission, received-wire audit': 1}
        e2e.composition_outcomes.clear()
        e2e.results.clear()
        with patch.object(e2e, 'replay_twin', return_value=(1, refusal, [])) as replay, \
             contextlib.redirect_stdout(io.StringIO()):
            e2e.audit_composition(server, 'mail_save_draft', {}, 1, refusal, {}, 0, 1)
            e2e.audit_composition(server, 'mail_send', {}, 1, refusal, {}, 0, None)
        assert replay.call_count == 2, 'a wire received before the call or by another call was attributed'
        assert e2e.composition_outcomes == {'refused before composing': 2}
    e2e.results.clear()
    e2e.composition_outcomes.clear()
    data = b'\n'.join(json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                                  'params': {'name': 'mail_send', 'arguments': {}}}).encode() for _ in range(2))
    with contextlib.redirect_stdout(io.StringIO()):
        e2e.audit_mcp_compositions(None, data, [{'id': 1, 'result': {}}], {}, 0, 0)
    assert e2e.composition_outcomes == {'unaudited': 1} and not all(ok for _, ok in e2e.results)
    e2e.results.clear()
    e2e.composition_outcomes.clear()


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
    untransmitted_classification(interrupted_run_audit())
    print('MIME capture: rejected wires, dot unstuffing, optional audit, interrupted-run and '
          'untransmitted-composition classification controls checked')


if __name__ == '__main__':
    main()
