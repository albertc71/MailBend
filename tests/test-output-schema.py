#!/usr/bin/env python3
"""Check output contract variants at feature integration boundaries."""
import copy
import importlib.util
from pathlib import Path
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('schema', ROOT / 'tools/gen-schema.py')
schema = importlib.util.module_from_spec(spec)
spec.loader.exec_module(schema)
checks = 0


def check(name, value, valid=True):
    global checks
    contract = schema.output_schema(name)
    Draft202012Validator.check_schema(contract)
    errors = list(Draft202012Validator(contract).iter_errors(value))
    assert (not errors) == valid, (name, value, [e.message for e in errors])
    checks += 1


hidden_count = dict(tag=0, bidi=0, zero_width=0)
hidden = dict(subject=hidden_count, body=hidden_count, **{"from": hidden_count},
              to=[hidden_count], cc=[], bcc=[], attachment_filenames=[])
sent = dict(ok=True, sent=True, message_id='<fixture@example.test>', recipients=1,
            server_reply='250 accepted', smtp_outcome='accepted', smtp_phase='data_reply',
            smtp_reason='accepted_by_server', next_action='Do not resend.',
            sent_copy='failed or unconfirmed', hidden_unicode=hidden)
check('mail_send', sent)
check('mail_send', {k: v for k, v in sent.items() if k != 'hidden_unicode'}, False)
check('mail_send', {**sent, 'hidden_unicode': {**hidden, 'body': {'tag': 0}}}, False)
check('mail_send', {**sent, 'hidden_unicode': {**hidden, 'body': {**hidden_count, 'tag': -1}}}, False)
check('mail_send', {**sent, 'smtp_outcome': 'unknown'}, False)
for outcome, phase, reason in [('not_sent', 'before_smtp', 'local_refusal'),
                               ('not_sent', 'before_data', 'stopped_before_data'),
                               ('not_sent', 'data_reply', 'explicit_rejection'),
                               ('unknown', 'data_reply', 'acceptance_unconfirmed'),
                               ('unknown', 'unknown', 'missing_progress')]:
    value = dict(error='fixture', smtp_outcome=outcome, smtp_phase=phase,
                 smtp_reason=reason, next_action='Inspect evidence.')
    for name in ('mail_send', 'mail_reply', 'mail_forward'):
        check(name, value)
        check(name, {**value, 'smtp_phase': 'accepted'}, False)
removed = dict(subject=1, body=2, to=[1], cc=[])
for name in ('mail_reply', 'mail_forward'):
    failure = dict(error='fixture', smtp_outcome='unknown', smtp_phase='data_reply',
                   smtp_reason='acceptance_unconfirmed', next_action='Inspect evidence.',
                   hidden_unicode=hidden, removed_tags=removed)
    check(name, failure)
    check(name, {**failure, 'removed_tags': {**removed, 'subject': -1}}, False)
    check(name, dict(error='early refusal'))
check('mail_save_draft', dict(dry_run=True, imap=['APPEND redacted'], hidden_unicode=hidden))
check('mail_send', dict(dry_run=True,
      smtp={'from': 'sender@example.test', 'rcpt': ['a@example.test'], 'data': '<1 bytes>',
            'sent_copy': False}, hidden_unicode=hidden))
selected = dict(folder='INBOX', uid=1, uidvalidity=7, section='1',
                content_type='text/plain', complete=True, scope='selected_part',
                message_complete=False, content='fixture', content_encoding='text')
check('mail_get', selected)
for mode in ('full', 'text', 'html', 'metadata'):
    for media in ('text/plain', 'text/html', 'application/pdf', ' Text/Plain;charset=utf-8', ' TEXT/HTML ; charset=utf-8'):
        value = {**selected, 'content_type': media,
                 'response': dict(projection=mode, max_bytes=1000,
                                  budget_scope='result_json_utf8', output_truncated=False,
                                  request_more='', content_complete=True)}
        main = media.split(';')[0].strip().lower()
        keep = mode == 'full' or (mode == 'text' and main == 'text/plain') or (
            mode == 'html' and main == 'text/html')
        if not keep:
            value.pop('content')
            value['response']['content_complete'] = False
        check('mail_get', value)
        bad = copy.deepcopy(value)
        if keep:
            bad.pop('content')
        else:
            bad['content'] = 'must not leak'
        check('mail_get', bad, False)
check('mail_get', {**selected, 'message_complete': True}, False)
search = dict(folder='INBOX', uidvalidity=7, total=1, messages=[],
              has_more=True, next_cursor='bound-cursor')
check('mail_search', search)
check('mail_search', {k: v for k, v in search.items() if k != 'has_more'}, False)
refresh = dict(folder='INBOX', uidvalidity=7, reset_required=False, complete=False,
               present=[dict(uid=1, flags=[])], absent=[], unknown=[2], reason='incomplete')
check('mail_refresh', refresh)
check('mail_refresh', {**refresh, 'present': [dict(uid=1)]}, False)
print(f'output schemas: {checks} checks passed')
