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
assert all(isinstance(entry.get("title"), str) and entry["title"].strip()
           for entry in schema.TOOLS), "each tool needs a human-readable title"
checks += 1
destructive_tools = {entry["name"] for entry in schema.TOOLS
                     if entry["annotations"]["destructiveHint"]}
assert destructive_tools == {"mail_mark_read", "mail_mark_unread", "mail_flag", "mail_unflag",
                             "mail_move", "mail_label", "mail_trash", "mail_delete",
                             "mail_rename_folder", "mail_triage"}, destructive_tools
assert all(entry["annotations"]["openWorldHint"] is True for entry in schema.TOOLS)
assert all(type(value) is bool for entry in schema.TOOLS
           for value in entry["annotations"].values())
checks += 3
interaction_tools = {entry["name"] for entry in schema.TOOLS
                     if entry.get("_meta", {}).get("anthropic/requiresUserInteraction") is True}
assert interaction_tools == {"mail_send", "mail_reply", "mail_forward", "mail_delete"}, interaction_tools
checks += 1
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
reply = {**sent, "removed_tags": removed, "quoted_original_truncated": False,
         "quoted_bytes": 12, "original_bytes": 12}
check("mail_reply", reply)
for marked in (True, False, "unverified"):
    value = {**reply, "original_marked": marked, "original_mark_reason": "fixture"}
    check("mail_reply", value)
    check("mail_reply", {k: v for k, v in value.items() if k != "original_mark_reason"}, False)
    check("mail_reply", {**value, "smtp_outcome": "unknown"}, False)
    check("mail_forward", value, False)
check("mail_reply", {**reply, "original_marked": "yes", "original_mark_reason": "fixture"}, False)
reply_input = next(t["inputSchema"] for t in schema.TOOLS if t["name"] == "mail_reply")
assert "mark_answered" not in reply_input["required"]
assert reply_input["properties"]["mark_answered"]["type"] == "boolean"
checks += 2
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

literal_link = "https://meet.google.com/abc-defg-hij"
meeting_fact = dict(kind="meeting_link", value=literal_link, source="text",
                    start=0, end=36, line=1, untrusted=True)
whole = dict(folder="INBOX", uid=1, uidvalidity=7, internal_date="", **{"from": ""},
             to="", cc="", reply_to="", subject="", date="", message_id="",
             in_reply_to="", references="", text=literal_link, html="", flags=[],
             seen=False, size=36, truncated=False, html_available=False, attachments=[], **metadata)
with_facts = {**whole, "facts": [meeting_fact],
              "facts_scan": {"scope": "returned_text", "limited": False}}
check("mail_get", whole)
check("mail_get", with_facts, False)
# attached_message_headers adds a sanitized summary only to attached messages.
summary = {"from": "a <a@example.invalid>", "to": "", "subject": "inner", "date": "", "message_id": ""}
attached_entry = {"filename": "", "content_type": "message/rfc822", "size": 9, "message": summary}
check("mail_get", {**whole, "attachments": [attached_entry]})
check("mail_get", {**whole, "attachments": [{**attached_entry, "content_type": "message/global"}]})
check("mail_get", {**with_facts, "attachments": [attached_entry]}, False)
check("mail_get", {**whole, "attachments": [{**attached_entry, "content_type": "application/pdf"}]}, False)
check("mail_get", {**whole, "attachments": [{**attached_entry, "message": {**summary, "cc": ""}}]}, False)
check("mail_get", {**whole, "attachments": [{**attached_entry, "message": {
    k: v for k, v in summary.items() if k != "date"}}]}, False)
check("mail_get", {**whole, "attachments": [{**attached_entry, "message": {**summary, "subject": "h" * 999}}]}, False)
# Jev never sees the summaries, so an annotated read showing one is scoped.
summary_reason = "Attached-message summaries were not included in the Jev request."
summarized = {**whole, "attachments": [{"filename": "a.bin", "content_type": "application/pdf", "size": 2},
                                       attached_entry]}
for mode, coverage in [("body", "partial"), ("headers", "headers_only")]:
    plain_jev = {"status": "checked", "model": "fixture", "content": mode,
                 "derived_from_untrusted_content": True, "decision": "proceeded", "signals": {},
                 "reasons": []}
    jev = {**plain_jev, "reasons": [summary_reason], "coverage": coverage}
    check("mail_get", {**summarized, "jev": jev})
    check("mail_get", {**with_facts, "attachments": [attached_entry], "jev": jev}, False)
    check("mail_get", {**summarized, "jev": plain_jev}, False)
    check("mail_get", {**summarized, "jev": {**plain_jev, "coverage": coverage}}, False)
    check("mail_get", {**summarized, "jev": {**jev, "coverage": "complete"}}, False)
    check("mail_get", {**summarized, "jev": {**jev, "reasons": [
        "Nested message text was not included in the Jev request."]}}, False)
    check("mail_get", {**whole, "jev": plain_jev})
    check("mail_get", {**whole, "jev": jev}, False)
for invalid in ("\n", "\r", "\t", "\x00", "\x1b", "\x7f", "\x85", "\u061c", "\u200e",
                "\u2028", "\u202e", "\u2066"):
    for key in summary:
        check("mail_get", {**whole, "attachments": [{**attached_entry,
            "message": {**summary, key: "safe" + invalid}}]}, False)
check("mail_get", {**whole, "facts": []}, False)
check("mail_get", {**whole, "facts_scan": {"scope": "returned_text", "limited": False}}, False)
check("mail_get", {**whole, "facts": [], "facts_scan": {"scope": "returned_text", "limited": False}}, False)
check("mail_get", {**with_facts, "facts": [meeting_fact] * 17}, False)
for change in ({"value": literal_link + "\n"}, {"value": literal_link + "?x"},
               {"source": "html"}, {"untrusted": False}, {"start": -1}, {"end": 65537},
               {"line": 0}, {"kind": "instruction"}):
    check("mail_get", {**with_facts, "facts": [{**meeting_fact, **change}]}, False)
check("mail_get", {**selected, "facts": [meeting_fact],
                   "facts_scan": {"scope": "returned_text", "limited": False}}, False)

# Literal nested-only contracts never widen the legacy selected variants.
nested_node = {"headers": {"from": "", "to": "", "subject": "inner", "date": "", "message_id": ""},
               "text": "hello", "attachments": [], "parse_complete": True, "omissions": []}
nested = {"folder": "INBOX", "uid": 7, "uidvalidity": 9, "section": "1",
          "content_type": "message/rfc822", "complete": True, "scope": "selected_part",
          "message_complete": False, "content": nested_node, "content_encoding": "message"}
check("mail_get", nested)
check("mail_get", {**nested, "content_type": 'message/rfc822; name="forward.eml"'})
check("mail_get", {**nested, "content_type": "message/global; charset=utf-8"})
check("mail_get", {**nested, "content_type": 'message/rfc822; name="a\r\nb"'})
check("mail_get", {**nested, "content_type": "message/rfc822\n"}, False)
for bad in ({"content_type": "text/plain"}, {"uid": 0}, {"uidvalidity": 0},
            {"section": "01"}, {"section": "1.0"}, {"section": "1\n"}):
    check("mail_get", {**nested, **bad}, False)
for encoding in ("text", "base64"):
    check("mail_get", {**nested, "content_encoding": encoding}, False)
check("mail_get", {**nested, "content": "hello"}, False)
for key in ("headers", "text", "attachments", "parse_complete", "omissions"):
    check("mail_get", {**nested, "content": {k: v for k, v in nested_node.items() if k != key}}, False)
check("mail_get", {**nested, "content": {**nested_node, "parse_complete": False}}, False)
check("mail_get", {**nested, "content": {**nested_node, "omissions": ["depth_limit"]}}, False)
for invalid in ("\n", "\r", "\t", "\x00", "\x7f", "\x85", "\u061c", "\u200e", "\u200f",
                "\u2028", "\u2029", "\u202a", "\u202e", "\u2066", "\u2069"):
    for key in nested_node["headers"]:
        check("mail_get", {**nested, "content": {**nested_node,
            "headers": {**nested_node["headers"], key: "safe" + invalid}}}, False)
check("mail_get", {**nested, "content": {**nested_node,
    "headers": {**nested_node["headers"], "subject": "h" * 999}}}, False)

def attached(inner):
    return {**nested_node, "attachments": [{"filename": "", "content_type": "message/rfc822",
                                             "size": 23, "message": inner}]}

check("mail_get", {**nested, "content": attached(attached(nested_node))})

def named(name, inner=None, node=nested_node):
    entry = {"filename": name, "content_type": "application/octet-stream", "size": 2}
    if inner is not None:
        entry = {**entry, "content_type": "message/rfc822", "message": inner}
    return {**node, "attachments": [entry]}

check("mail_get", {**nested, "content": named("a  From: x")})
check("mail_get", {**nested, "content": named("a  b", nested_node)})
for invalid in ("\n", "\r", "\t", "\x00", "\x85", "\u202e", "\u2066"):
    for content in (named("a" + invalid), named("a" + invalid, nested_node),
                    attached(named("a" + invalid)), attached(attached(named("a" + invalid)))):
        check("mail_get", {**nested, "content": content}, False)
check("mail_get", {**nested, "content": attached(attached(attached(nested_node)))}, False)
cut = {**nested_node, "attachments": [{"filename": "", "content_type": "message/rfc822", "size": 23}],
       "parse_complete": False, "omissions": ["depth_limit"]}
check("mail_get", {**nested, "content": {**attached({**attached(cut), "parse_complete": False,
    "omissions": ["depth_limit"]}), "parse_complete": False, "omissions": ["depth_limit"]}})
check("mail_get", {**nested, "content": attached(attached({**cut, "parse_complete": True, "omissions": []}))}, False)
check("mail_get", {**nested, "content": attached(attached(cut))}, False)
wrong_reason = {**cut, "omissions": ["additional_readable_part"]}
check("mail_get", {**nested, "content": {**attached({**attached(wrong_reason),
    "parse_complete": False, "omissions": ["additional_readable_part"]}),
    "parse_complete": False, "omissions": ["additional_readable_part"]}}, False)
for level in (cut, attached(cut)):
    check("mail_get", {**nested, "content": level}, False)
wrong_parent = {**attached({**attached(cut), "parse_complete": False,
                           "omissions": ["depth_limit"]}),
                "parse_complete": False, "omissions": ["additional_readable_part"]}
check("mail_get", {**nested, "content": wrong_parent}, False)
notice = {"projection": "full", "max_bytes": 1000, "budget_scope": "result_json_utf8",
          "output_truncated": False, "request_more": "retry", "content_complete": True}
check("mail_get", {**nested, "response": notice})
for mode in ("text", "html", "metadata"):
    check("mail_get", {**nested, "response": {**notice, "projection": mode}}, False)
check("mail_get", {**nested, "response": {**notice, "output_truncated": True}}, False)
check("mail_get", {**nested, "response": {**notice, "content_complete": False}}, False)
for mode, coverage, reason in [("body", "partial", "Nested message text was not included in the Jev request."),
        ("headers", "headers_only", "Only parent header facts were eligible for checking; nested headers and text were not included.")]:
    jev = {"status": "unchecked", "model": "fixture", "content": mode,
           "derived_from_untrusted_content": True, "decision": "proceeded", "signals": {},
           "reasons": ["transport failure", reason], "coverage": coverage}
    check("mail_get", {**nested, "jev": jev})
    check("mail_get", {**nested, "jev": {k: v for k, v in jev.items() if k != "coverage"}}, False)
    check("mail_get", {**nested, "jev": {**jev, "reasons": ["transport failure"]}}, False)
    check("mail_get", {**nested, "jev": {**jev, "coverage": "complete"}}, False)
    check("mail_get", {**nested, "jev": {**jev, "extra": True}}, False)

# Each opt-in keeps its own closed result shape.
check("mail_get", {**nested, "facts": [meeting_fact],
                   "facts_scan": {"scope": "returned_text", "limited": False}}, False)
check("mail_get", {**with_facts, "content": nested_node, "content_encoding": "message"}, False)
check("mail_get", {**nested, "content": {**nested_node, "facts": [],
                   "facts_scan": {"scope": "returned_text", "limited": False}}}, False)

print(f'output schemas: {checks} checks passed')
