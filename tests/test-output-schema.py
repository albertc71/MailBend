#!/usr/bin/env python3
"""Check output contract variants at feature integration boundaries."""
import copy
import json
import re
from functools import cache
import importlib.util
from pathlib import Path
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('schema', ROOT / 'tools/gen-schema.py')
schema = importlib.util.module_from_spec(spec)
spec.loader.exec_module(schema)
checks = 0

# :04d pads small indices but does not truncate indices above 9999.
PIECE_CALL = re.compile(r'schema_piece\.p(?:[0-9]{4}|[1-9][0-9]{4,})\(\)')


def check_rendered_text(tools):
    """Decode generated defs and the final aggregator, not generator internals."""
    rendered = schema.render(tools)
    assert rendered == schema.render(tools), "generation must be deterministic"
    original, selected = rendered.split("# Select only known generated definitions, in schema order.\n")
    assert re.findall(r'^def ([a-zA-Z0-9_.]+)\(', selected, re.M) == [
        "tool_defs.named", "tool_defs.contains", "tool_defs.select",
        "tool_defs.selected", "tool_defs_for"]
    cases = re.findall(r'    case "([a-zA-Z0-9_]+)":\n      (tool_defs\.[a-zA-Z0-9_]+)\(\)', selected)
    assert cases == [(entry["name"], "tool_defs." + entry["name"]) for entry in tools]
    order = re.search(r'tool_defs.selected\(\[\n(.*?)\], names\)', selected, re.S)
    assert order
    assert json.loads("[" + order.group(1) + "]") == [entry["name"] for entry in tools]
    declarations = re.findall(
        r'^def ([a-zA-Z0-9_.]+)\(\) -> String:\n(.*?)(?=^def |\Z)', original, re.M | re.S)
    all_names = re.findall(r'^def ([a-zA-Z0-9_.]+)\(', original, re.M)
    assert [name for name, _ in declarations] == all_names
    assert len(set(all_names)) == len(all_names)
    values, wire = {}, None
    for name, body in declarations:
        body = "\n".join(line for line in body.splitlines()
                         if not line.startswith("#")).strip()
        if name == "tool_defs":
            match = re.fullmatch(r'"\[" \+\+ String.join\(\[\s*(.*?)\], ","\) \+\+ "\]"', body, re.S)
            assert match, body
            calls = [term.strip() for term in match.group(1).split(",") if term.strip()]
            assert all(re.fullmatch(r'tool_defs\.[a-zA-Z0-9_]+\(\)', call) for call in calls)
            wire = "[" + ",".join(values[call[:-2]] for call in calls) + "]"
            continue
        match = re.fullmatch(r'String.concat\(\[\n(.*?)\]\)', body, re.S)
        if match:
            pieces = []
            for line in match.group(1).splitlines():
                term = line.strip().removesuffix(",")
                if term.startswith('"'):
                    pieces.append(json.loads(term))
                else:
                    assert PIECE_CALL.fullmatch(term), term
                    pieces.append(values[term[:-2]])
            values[name] = "".join(pieces)
        else:
            values[name] = json.loads(body)
    for entry in tools:
        assert values['tool_defs.' + entry['name']] == json.dumps(
            entry, ensure_ascii=True, separators=(",", ":"))
    assert wire == json.dumps(tools, ensure_ascii=True, separators=(",", ":"))
    return rendered

valid_indices = (0, 9, 9999, 10000, 123456)
invalid_calls = ("schema_fragment.p0000()", "schema_piece.p0()",
                 "schema_piece.p00000()", "schema_piece.p-001()",
                 "schema_piece.p0000", "schema_piece.p0000()suffix")
for index in valid_indices:
    assert PIECE_CALL.fullmatch(f"schema_piece.p{index:04d}()")
for invalid in invalid_calls:
    assert not PIECE_CALL.fullmatch(invalid), invalid
checks += len(valid_indices) + len(invalid_calls)

check_rendered_text(schema.TOOLS)
fixture = [{"name": name, "description": ('quoted "value" \\ slash 雪 🌱 ' * 12),
            "empty": "", "control": "\n\t\u0000"} for name in ("first", "second")]
assert "schema_piece.p0000()" in check_rendered_text(fixture)
check_rendered_text([])
checks += 3


@cache
def validator(name):
    contract = schema.output_schema(name)
    Draft202012Validator.check_schema(contract)
    return Draft202012Validator(contract)


def check(name, value, valid=True):
    global checks
    errors = list(validator(name).iter_errors(value))
    assert (not errors) == valid, (name, value, [e.message for e in errors])
    checks += 1


probe = dict(ok=True, account="fixture@example.test", imap_host="localhost", tls_verified=True,
             capabilities=[], idle=False, move=False, uidplus=False, folder_count=1,
             special_use={k: None for k in ("inbox", "drafts", "sent", "trash", "junk", "archive")})
for storage in ("unknown", dict(used_kib=95, limit_kib=100, percent=95),
                dict(used_kib=150, limit_kib=100, percent=150)):
    check("mail_probe", {**probe, "storage": storage})
for storage in ({}, None, "unsupported", dict(used_kib=-1, limit_kib=100, percent=0),
                dict(used_kib=0, limit_kib=0, percent=0),
                dict(used_kib=4294967296, limit_kib=100, percent=95),
                dict(used_kib=95, limit_kib=100, percent=95.5)):
    check("mail_probe", {**probe, "storage": storage}, False)
check("mail_probe", probe, False)

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

metadata = dict(list_id=None, auto_submitted=None, bulk=None,
                unsubscribe=dict(mailto=None, https=None, one_click=False),
                answered=False, forwarded=False)
message = dict(date='', **{'from': ''}, to='', cc='', subject='', message_id='',
               internal_date='', uid=1, size=0, flags=[], seen=False, flagged=False,
               **metadata)
check('mail_search', {**search, 'messages': [message]})
for key in metadata:
    check('mail_search', {**search, 'messages': [{k: v for k, v in message.items()
                                                if k != key}]}, False)
check('mail_search', {**search, 'messages': [{**message, 'bulk': 'guessed'}]}, False)
check('mail_search', {**search, 'messages': [{**message, 'unsubscribe': {
    'mailto': None, 'https': None, 'one_click': 'yes'}}]}, False)
for key in ('list_id', 'auto_submitted'):
    assert 'Untrusted sender-supplied' in schema.METADATA[key]['description']
    checks += 1
for key in ('mailto', 'https'):
    assert 'Untrusted sender-supplied' in schema.METADATA['unsubscribe']['properties'][key]['description']
    checks += 1

image = dict(section='2', name='photo.jpg', fate='used', format='jpeg', bytes=120,
             width=280, height=280, metadata_removed_bytes=40)
image_contract = Draft202012Validator(schema.IMAGE_USED)
assert image_contract.is_valid(image)
assert image_contract.is_valid({**image, 'metadata_removed_bytes': 0})
assert not image_contract.is_valid({k: v for k, v in image.items()
                                    if k != 'metadata_removed_bytes'})
assert not image_contract.is_valid({**image, 'metadata_removed_bytes': -1})
assert not image_contract.is_valid({**image, 'metadata_removed_bytes': '40'})
checks += 5
print(f'output schemas: {checks} checks passed')
