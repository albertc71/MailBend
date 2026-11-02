"""Synthetic metadata briefs. No model, real account or external endpoint."""
import copy
import importlib.util
import json
import time
from collections import Counter
from email import policy
from email.parser import Parser
from email.utils import getaddresses, parsedate_to_datetime
from datetime import datetime, timezone, timedelta


def run(t, work):
    now = time.time()

    def message(uid, sender, headers='', flags=()):
        return dict(uid=uid, flags=list(flags), internaldate=time.strftime(
            '%d-%b-%Y %H:%M:%S +0000', time.gmtime(now - 86400)),
            raw=f'From: {sender}\r\nSubject: Brief item {uid}\r\n{headers}\r\nBody')

    fixture = copy.deepcopy(t.FIX)
    fixture['mailboxes']['INBOX']['messages'] = [
        message(1, 'known@example.test', f'To: {fixture["user"]}\r\n'),
        message(2, 'new@example.test', f'Cc: {fixture["user"]}\r\n'),
        message(3, 'list@example.test', 'List-Id: News <news.example.test>\r\n'),
        message(4, 'robot@example.test', 'Auto-Submitted: auto-generated\r\n'),
        message(5, 'known@example.test', '', ['\\Seen']),
        message(6, 'broken', f'To: {fixture["user"]}\r\n'),
        message(7, 'list@example.test', 'List-Id: News <news.example.test>\r\n')]
    fixture['mailboxes']['Sent Messages']['messages'] = [
        message(1, fixture['user'], 'To: Known <known@example.test>\r\n')]
    uidv = fixture['mailboxes']['INBOX']['uidvalidity']
    srv = t.Server(work, fixture=fixture)
    try:
        before = srv.st()
        code, result = t.tool(srv, 'mail_brief', {}, MAILBEND_READ_ONLY='1',
                              MAILBEND_TYPESAFE='0', MAILBEND_TYPESAFE_HELPER='/nonexistent-brief-helper')
        rows = result.get('messages', [])
        t.check('brief: one group per selected unseen UID in arrival order', code == 0 and
                [m['uid'] for m in rows] == [1, 2, 3, 4, 6, 7] and
                [m['group'] for m in rows] == ['people', 'unknown_people', 'lists', 'automated',
                                               'unknown_people', 'lists'], result)
        t.check('brief: delivery is independent of sender evidence',
                [m['delivery'] for m in rows] == ['direct', 'cc_only', 'other_or_unknown',
                                                 'other_or_unknown', 'direct', 'other_or_unknown'], result)
        counts = Counter((m['group'], m['group_key']) for m in rows)
        t.check('brief: group counts describe exactly the returned partition',
                {(g['group'], g['group_key']): g['count'] for g in result.get('groups', [])} == counts
                and sum(g['count'] for g in result.get('groups', [])) == len(rows), result)
        t.check('brief: explicit bounded stored-header scope, not lifetime first-time',
                result.get('correspondence', {}).get('scope') == 'stored_sent_headers_window' and
                result.get('correspondence', {}).get('coverage', {}).get('complete') is True and
                not any(m['group'] == 'new_people' for m in rows), result)
        t.check('brief: one Sent scan, independent of sender count',
                sum(' UID SEARCH ' in line for line in srv.log_lines()) == 2, srv.log_lines())
        code, page = t.tool(srv, 'mail_brief', {'since_uid': 0, 'limit': 2})
        t.check('brief: arrivals page retains oldest complete prefix', code == 0 and
                [m['uid'] for m in page.get('messages', [])] == [1, 2] and
                page.get('next_since_uid') == 2 and page.get('has_more') is True, page)
        code, page = t.tool(srv, 'mail_brief', {'since_uid': 2, 'uidvalidity': uidv})
        t.check('brief: arrival continuation includes already-read new mail', code == 0 and
                [m['uid'] for m in page.get('messages', [])] == [3, 4, 5, 6, 7] and
                page.get('next_since_uid') == 7 and not page.get('has_more'), page)
        code, small = t.tool(srv, 'mail_brief', {'since_uid': 0, 'max_response_bytes': 256})
        t.check('brief: inadequate budget returns no checkpoint or dropped items',
                code != 0 and 'next_since_uid' not in small and 'messages' not in small, small)
        code, retry = t.tool(srv, 'mail_brief', {'since_uid': 0, 'max_response_bytes': 20000})
        t.check('brief: same checkpoint retry returns every selected UID', code == 0 and
                [m['uid'] for m in retry.get('messages', [])] == list(range(1, 8)) and
                retry.get('next_since_uid') == 7, retry)
        bound = copy.deepcopy(retry)
        cap = len(json.dumps(bound, ensure_ascii=False, separators=(',', ':')).encode())
        for _ in range(3):
            bound['response']['max_bytes'] = cap
            cap = len(json.dumps(bound, ensure_ascii=False, separators=(',', ':')).encode())
        code, exact = t.tool(srv, 'mail_brief', {'since_uid': 0, 'max_response_bytes': cap})
        t.check('brief: exact UTF-8 metadata budget fits', code == 0 and
                len(json.dumps(exact, ensure_ascii=False, separators=(',', ':')).encode()) == cap, exact)
        code, under = t.tool(srv, 'mail_brief', {'since_uid': 0, 'max_response_bytes': cap - 1})
        t.check('brief: one byte below immutable result refuses the checkpoint', code != 0 and
                'next_since_uid' not in under, under)
        code, stale = t.tool(srv, 'mail_brief', {'since_uid': 2, 'uidvalidity': 3})
        t.check('brief: stale identity returns no checkpoint', code != 0 and
                'next_since_uid' not in stale and 'UIDVALIDITY' in stale.get('error', ''), stale)
        offset = len(srv.log_lines())
        code, empty = t.tool(srv, 'mail_brief', {'since_uid': 4294967295, 'uidvalidity': uidv})
        t.check('brief: max UID examines only and preserves empty cursor', code == 0 and
                empty.get('messages') == [] and empty.get('next_since_uid') == 4294967295 and
                sum(' LOGIN ' in line for line in srv.log_lines()[offset:]) == 1, empty)
        t.check('brief: no writes, Seen changes, full bodies or TypeSafe requirement',
                before == srv.st() and not any(' SELECT ' in line or 'BODY[' in line or
                    any(word in line for word in t.MUTATING_COMMANDS) for line in srv.log_lines()))
    finally:
        srv.stop()

    # UIDNEXT is a snapshot boundary, not the maximum unseen UID. The existing
    # override also models messages arriving after EXAMINE but before SEARCH.
    for scenario, messages, high, limit, expected, cursor, basis in (
        ('empty folder', [], 0, 50, [], 0, 'high_water'),
        ('all seen', [message(8, 'known@example.test', flags=['\\Seen'])],
         8, 50, [], 8, 'high_water'),
        ('seen higher UID', [message(2, 'new@example.test'),
                            message(8, 'known@example.test', flags=['\\Seen'])],
         8, 50, [2], 8, 'high_water'),
        ('capped unseen', [message(2, 'new@example.test'), message(4, 'new@example.test'),
                          message(8, 'known@example.test', flags=['\\Seen'])],
         8, 1, [2], 2, 'selected_prefix'),
        ('snapshot race', [message(2, 'new@example.test'),
                           message(5, 'known@example.test', flags=['\\Seen']),
                           message(6, 'new@example.test')],
         4, 50, [2], 4, 'high_water'),
    ):
        changed = copy.deepcopy(fixture)
        changed['mailboxes']['INBOX']['messages'] = messages
        changed['uidnext_response'] = {'INBOX': high + 1}
        srv = t.Server(work, fixture=changed)
        try:
            code, page = t.tool(srv, 'mail_brief', {'limit': limit})
            t.check(f'brief: {scenario} uses the safe snapshot/prefix cursor', code == 0 and
                    [m['uid'] for m in page.get('messages', [])] == expected and
                    page.get('next_since_uid') == cursor and page.get('checkpoint_basis') == basis, page)
            code, follow = t.tool(srv, 'mail_brief', {'since_uid': cursor, 'uidvalidity': uidv})
            t.check(f'brief: {scenario} continuation loses no arrival or backlog UID', code == 0 and
                    [m['uid'] for m in follow.get('messages', [])] ==
                    [m['uid'] for m in messages if m['uid'] > cursor], follow)
        finally:
            srv.stop()

    for invalid in (None, 0, '07', 'not-a-number', 4294967296):
        changed = copy.deepcopy(fixture)
        changed['uidnext_response'] = {'INBOX': invalid}
        srv = t.Server(work, fixture=changed)
        try:
            code, page = t.tool(srv, 'mail_brief')
            t.check(f'brief: invalid snapshot UIDNEXT {invalid!r} fails closed', code != 0 and
                    'next_since_uid' not in page and 'UIDNEXT' in page.get('error', ''), page)
        finally:
            srv.stop()

    for mode in ('empty-literal', 'empty-quoted', 'nil'):
        changed = copy.deepcopy(fixture)
        changed['mailboxes']['INBOX']['messages'][0].update(
            raw='X-Unrequested: synthetic', header_fetch_value=mode)
        srv = t.Server(work, fixture=changed)
        try:
            code, page = t.tool(srv, 'mail_brief', {'limit': 1})
            if mode == 'nil':
                t.check('brief: persistent NIL remains missing evidence, no checkpoint',
                        code != 0 and 'next_since_uid' not in page, page)
            else:
                rows = page.get('messages', [])
                t.check(f'brief: {mode} remains selected exactly once', code == 0 and
                        [m['uid'] for m in rows] == [1] and
                        rows[0]['group'] == 'unknown_people' and page.get('next_since_uid') == 1, page)
        finally:
            srv.stop()

    changed = copy.deepcopy(fixture)
    changed['mailboxes']['INBOX']['messages'] = [
        message(1, 'known@example.test', f'To: {fixture["user"]}\r\nReferences: ' + 'x' * 5120 + '\r\n'),
        message(2, 'list@example.test', 'List-Id: news.example.test\r\nList-Unsubscribe: ' + 'x' * 5120 + '\r\n'),
        message(3, 'known@example.test', 'To: ' + 'x' * 4097 + '\r\n'),
        message(4, 'list@example.test', 'List-Id: one\r\nList-Id: two\r\n')]
    srv = t.Server(work, fixture=changed)
    try:
        code, page = t.tool(srv, 'mail_brief')
        rows = page.get('messages', [])
        t.check('brief: only relevant fields consume classification bound; duplicates stay conservative',
                code == 0 and [m['group'] for m in rows] ==
                ['people', 'lists', 'unknown_people', 'unknown_people'] and
                rows[0]['delivery'] == 'direct' and rows[2]['delivery'] == 'other_or_unknown', page)
    finally:
        srv.stop()

    # Charge unfolded UTF-8 names+values plus colon/space/CRLF per field.
    # Distribute the boundary across fields; no individual value exceeds it.
    boundary = copy.deepcopy(fixture)
    rows = []
    for uid, (total, multibyte) in enumerate(((4096, False), (4097, False),
                                             (4096, True), (4097, True)), 1):
        fields = [('From', 'known@example.test'), ('To', fixture['user']),
                  ('List-Id', ''), ('Precedence', '')]
        room = total - sum(len(name.encode()) + len(value.encode()) + 4 for name, value in fields)
        first = room // 2
        list_value = ('é' * (first // 2) + 'x' * (first % 2)) if multibyte else 'x' * first
        fields[2] = ('List-Id', list_value)
        fields[3] = ('Precedence', 'x' * (room - first))
        assert sum(len(name.encode()) + len(value.encode()) + 4 for name, value in fields) == total
        assert all(len(value.encode()) < 4096 for _, value in fields)
        headers = ''.join(f'{name}: {value}\r\n' for name, value in fields[1:])
        rows.append(message(uid, fields[0][1], headers))
    boundary['mailboxes']['INBOX']['messages'] = rows
    srv = t.Server(work, fixture=boundary)
    try:
        code, result = t.tool(srv, 'mail_brief')
        actual = result.get('messages', [])
        t.check('brief: exact UTF-8 classification budget 4096/4097 across fields', code == 0 and
                [m['uid'] for m in actual] == [1, 2, 3, 4] and
                [m['group'] for m in actual] == ['lists', 'unknown_people', 'lists', 'unknown_people'] and
                [m['delivery'] for m in actual] == ['direct', 'other_or_unknown', 'direct', 'other_or_unknown'] and
                result.get('next_since_uid') == 4, result)
    finally:
        srv.stop()

    for failure in ('missing_fetch', 'identity_race', 'search_missing', 'search_malformed'):
        changed = copy.deepcopy(fixture)
        extra = ()
        if failure == 'missing_fetch':
            changed['mailboxes']['INBOX']['messages'][0]['omit_fetch_data'] = True
        elif failure == 'identity_race':
            changed['examine_changes'] = [{'at': 2, 'uidvalidity': 99}]
        else:
            extra = ('--search-response', failure.removeprefix('search_'))
        srv = t.Server(work, fixture=changed, extra=extra)
        try:
            code, result = t.tool(srv, 'mail_brief', {'since_uid': 0})
            t.check(f'brief: {failure} cannot commit a checkpoint', code != 0 and
                    'next_since_uid' not in result and 'messages' not in result, result)
        finally:
            srv.stop()

    partial = copy.deepcopy(fixture)
    partial['mailboxes']['Sent Messages']['messages'] = [
        message(i, partial['user'], 'To: known@example.test\r\n') for i in range(1, 102)]
    srv = t.Server(work, fixture=partial)
    try:
        code, result = t.tool(srv, 'mail_brief')
        rows = {m['uid']: m for m in result.get('messages', [])}
        t.check('brief: positive observations survive capped coverage, absence stays unknown',
                code == 0 and rows.get(1, {}).get('group') == 'people' and
                rows.get(2, {}).get('group') == 'unknown_people' and
                result.get('correspondence', {}).get('coverage', {}).get('complete') is False, result)
    finally:
        srv.stop()

    missing = copy.deepcopy(fixture)
    del missing['mailboxes']['Sent Messages']
    srv = t.Server(work, fixture=missing)
    try:
        code, result = t.tool(srv, 'mail_brief', {'limit': 1})
        t.check('brief: missing Sent retains message and explicit unknown coverage', code == 0 and
                result.get('messages', [{}])[0].get('group') == 'unknown_people' and
                result.get('correspondence', {}).get('coverage', {}).get('complete') is False, result)
    finally:
        srv.stop()

    sender_cap = copy.deepcopy(fixture)
    sender_cap['mailboxes']['INBOX']['messages'] = [
        message(i, f'person{i}@example.test', f'To: {sender_cap["user"]}\r\n') for i in range(1, 52)]
    sender_cap['mailboxes']['Sent Messages']['messages'] = [
        message(1, sender_cap['user'], 'To: person1@example.test,person51@example.test\r\n')]
    srv = t.Server(work, fixture=sender_cap)
    try:
        code, result = t.tool(srv, 'mail_brief', {'limit': 100})
        rows = result.get('messages', [])
        coverage = result.get('correspondence', {})
        t.check('brief: sender cap does not omit messages or invent negative evidence', code == 0 and
                len(rows) == 51 and rows[0]['group'] == 'people' and rows[-1]['group'] == 'unknown_people' and
                coverage.get('selected_senders') == 50 and coverage.get('total_senders') == 51, result)
    finally:
        srv.stop()

    srv = t.Server(work, fixture=fixture)
    ts = t.TypeSafe(work)
    try:
        code, result = t.tool(srv, 'mail_brief', {'limit': 2},
                              **t.jev_env(ts, t.typesafe_key_file(work)))
        rows = result.get('messages', [])
        t.check('brief: fake Jev annotations reach every selected message without regrouping',
                code == 0 and len(rows) == 2 and all('jev' in m for m in rows) and
                [m['group'] for m in rows] == ['people', 'unknown_people'] and ts.requests(), result)
    finally:
        ts.stop()
        srv.stop()

    persona(t, work)


def persona(t, work):
    spec = importlib.util.spec_from_file_location('brief_persona', t.ROOT / 'tools/generate-persona.py')
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    fixture, labels = generator.generate()
    srv = t.Server(work, fixture=fixture)
    calls = []
    original_tool = t.tool

    def observed_tool(*args, **kwargs):
        calls.append(args[1])
        return original_tool(*args, **kwargs)

    t.tool = observed_tool
    try:
        before = srv.st()
        code, result = t.tool(srv, 'mail_brief', {'since_uid': 0, 'limit': 20},
                              MAILBEND_TYPESAFE='0', MAILBEND_TYPESAFE_HELPER='/nonexistent-brief-helper')
        expected = fixture['mailboxes']['INBOX']['messages'][:20]
        rows = result.get('messages', [])
        start = (datetime.now(timezone.utc) - timedelta(days=30)).date()
        candidates = [m for m in fixture['mailboxes']['Sent Messages']['messages']
                      if parsedate_to_datetime(m['internaldate'].replace('-', ' ')).date() >= start]
        known = set()
        for m in sorted(candidates, key=lambda m: m['uid'], reverse=True)[:100]:
            parsed = Parser(policy=policy.default).parsestr(m['raw'])
            known.update(a.lower() for _, a in getaddresses([str(parsed.get(k, '')) for k in ('To', 'Cc', 'Bcc')]))
        expected_rows = []
        for m in expected:
            parsed = Parser(policy=policy.default).parsestr(m['raw'])
            sender = getaddresses([str(parsed['From'])])[0][1].lower()
            group = 'people' if sender in known else 'unknown_people'
            if parsed.get('List-Id'):
                group = 'lists'
            elif str(parsed.get('Auto-Submitted', 'no')).lower() != 'no' or str(parsed.get('Precedence', '')).lower() in ('bulk', 'list', 'junk'):
                group = 'automated'
            expected_rows.append((m['uid'], str(parsed['Subject']), str(parsed['From']), group))
        t.check('brief persona: exact metadata inventory in at most two actual tool calls',
                code == 0 and len(calls) <= 2 and
                [(m['uid'], m['subject'], m['from'], m['group']) for m in rows] == expected_rows
                and before == srv.st(), result)
        t.check('brief persona: independent metadata task performs no body fetch or writes',
                not any(' SELECT ' in line or 'BODY.PEEK[]' in line or
                        any(word in line for word in t.MUTATING_COMMANDS) for line in srv.log_lines()))
        print('brief persona measured', json.dumps(dict(calls=len(calls),
              imap_logins=sum(' LOGIN ' in line for line in srv.log_lines()),
              selected_messages=len(rows), result_json_utf8=len(json.dumps(result,
              ensure_ascii=False, separators=(',', ':')).encode())), sort_keys=True))
    finally:
        t.tool = original_tool
        srv.stop()
