"""Synthetic unseen cursor behavior; no shared server hooks or real accounts."""
import copy
import json


def run(t, work):
    def message(uid, flags=()):
        return dict(uid=uid, flags=list(flags), internaldate='01-Nov-2026 00:00:00 +0000',
                    raw=f'From: broken\r\nSubject: Cursor {uid}\r\n\r\nSynthetic')

    fixture = copy.deepcopy(t.FIX)
    fixture['mailboxes']['INBOX']['messages'] = [message(1), message(3), message(5),
                                                  message(8, ['\\Seen']), message(9, ['\\Deleted'])]
    uidv = fixture['mailboxes']['INBOX']['uidvalidity']
    token = dict(version=1, mode='unseen', folder='INBOX', uidvalidity=uidv, after_uid=1, high_uid=9)

    def no_cursor(result):
        return 'next_continuation' not in result and 'next_since_uid' not in result

    srv = t.Server(work, fixture=fixture)
    try:
        before = srv.st()
        args, seen = {'limit': 1}, []
        for expected_uid, more in ((1, True), (3, True), (5, False)):
            code, page = t.tool(srv, 'mail_brief', args, MAILBEND_READ_ONLY='1')
            rows = page.get('messages', [])
            seen += [m['uid'] for m in rows]
            nxt = page.get('next_continuation')
            t.check('brief continuation: each page retains original identity/highwater', code == 0 and
                    [m['uid'] for m in rows] == [expected_uid] and page.get('has_more') is more and
                    (nxt == dict(token, after_uid=expected_uid) if more else nxt is None) and
                    page.get('next_since_uid') == (expected_uid if more else 9), page)
            args = {'continuation': nxt, 'limit': 1}
        searches = [x for x in srv.log_lines() if ' UID SEARCH ' in x]
        t.check('brief continuation: server-bounded unseen ranges advance without changing mode',
                seen == [1, 3, 5] and len(searches) == 3 and all('UNSEEN UNDELETED UID ' in x for x in searches)
                and all(x.endswith(r) for x, r in zip(searches, ('UID 1:9', 'UID 2:9', 'UID 4:9'))), searches)
        for projection in ('metadata', 'full', 'text', 'html'):
            code, projected = t.tool(srv, 'mail_brief', {'limit': 1, 'projection': projection,
                                                       'max_response_bytes': 8192})
            t.check('brief continuation: projection preserves the complete partial cursor', code == 0 and
                    projected.get('next_continuation') == token and
                    [m['uid'] for m in projected.get('messages', [])] == [1], projected)
        t.check('brief continuation: no flags or messages changed', srv.st() == before and
                not any(' SELECT ' in x or any(word in x for word in t.MUTATING_COMMANDS)
                        for x in srv.log_lines()))
    finally:
        srv.stop()

    # Duplicate UIDs within one SEARCH line exercise selection deduplication.
    # The older "duplicate" mode repeats the entire response, which is invalid
    # evidence and must not be accepted as a complete SEARCH.
    srv = t.Server(work, fixture=fixture, extra=('--search-response', 'duplicate-uids'))
    try:
        code, first = t.tool(srv, 'mail_brief', {'limit': 2})
        cursor = first.get('next_continuation')
        t.check('brief continuation: duplicate SEARCH UIDs do not consume page slots',
                code == 0 and [m['uid'] for m in first.get('messages', [])] == [1, 3]
                and cursor == dict(token, after_uid=3) and first.get('has_more') is True
                and first.get('next_since_uid') == 3, first)
        code, last = t.tool(srv, 'mail_brief', {'continuation': cursor, 'limit': 2})
        t.check('brief continuation: duplicate SEARCH UIDs retain each UID once across pages',
                code == 0 and [m['uid'] for m in last.get('messages', [])] == [5]
                and last.get('next_continuation') is None and last.get('has_more') is False
                and last.get('next_since_uid') == 9, last)
        replies = [entry['line'] for entry in srv.log_records()
                   if entry['proto'] == 'imap-search-response']
        t.check('brief continuation: duplicate fixture emits duplicate UIDs on both pages',
                replies == ['* SEARCH 1 1 3 3 5 5\r\n', '* SEARCH 5 5\r\n'], replies)
        for page, count in ((first, 2), (last, 1)):
            t.check('brief continuation: duplicate SEARCH group counts match returned messages',
                    page.get('groups') == [{'group': 'unknown_people', 'group_key': None, 'count': count}]
                    and sum(group['count'] for group in page.get('groups', []))
                    == len(page.get('messages', [])), page)
    finally:
        srv.stop()

    for global_mode, mailbox_mode, expected_replies in (
            ('normal', 'duplicate-uids', ['* SEARCH 1 1 3 3 5 5\r\n']),
            ('duplicate-uids', 'normal', [])):
        override = copy.deepcopy(fixture)
        override['search_responses'] = {'INBOX': mailbox_mode}
        srv = t.Server(work, fixture=override, extra=('--search-response', global_mode))
        try:
            code, page = t.tool(srv, 'mail_brief', {'limit': 2})
            t.check(f'brief continuation: {mailbox_mode} mailbox override retains page selection',
                    code == 0 and [m['uid'] for m in page.get('messages', [])] == [1, 3]
                    and page.get('next_continuation') == dict(token, after_uid=3)
                    and page.get('groups') == [
                        {'group': 'unknown_people', 'group_key': None, 'count': 2}], page)
            replies = [entry['line'] for entry in srv.log_records()
                       if entry['proto'] == 'imap-search-response']
            t.check(f'brief continuation: {mailbox_mode} mailbox override controls observation',
                    replies == expected_replies, replies)
        finally:
            srv.stop()

    srv = t.Server(work, fixture=fixture, extra=('--search-response', 'duplicate'))
    try:
        code, result = t.tool(srv, 'mail_brief', {'limit': 2})
        t.check('brief continuation: repeated SEARCH responses cannot advance a cursor',
                code != 0 and no_cursor(result), result)
    finally:
        srv.stop()

    # The original failure: a tiny old unread set below >10000 already-seen UIDs.
    large = copy.deepcopy(fixture)
    large['mailboxes']['INBOX']['messages'] = [message(1), message(3)] + [
        message(i, ['\\Seen']) for i in range(4, 10006)]
    srv = t.Server(work, fixture=large)
    try:
        code, first = t.tool(srv, 'mail_brief', {'limit': 1})
        cursor = first.get('next_continuation')
        t.check('brief continuation: large seen tail does not consume unseen SEARCH cap', code == 0 and
                [m['uid'] for m in first.get('messages', [])] == [1] and
                cursor == dict(token, high_uid=10005), first)
        code, last = t.tool(srv, 'mail_brief', {'continuation': cursor, 'limit': 1})
        t.check('brief continuation: completes old unread backlog without seen amplification', code == 0 and
                [m['uid'] for m in last.get('messages', [])] == [3] and
                last.get('next_continuation') is None and last.get('next_since_uid') == 10005, last)
        code, legacy = t.tool(srv, 'mail_brief', {'since_uid': 1, 'uidvalidity': uidv})
        t.check('brief continuation: legacy arrival semantics remain explicit and capped',
                code != 0 and no_cursor(legacy), legacy)
    finally:
        srv.stop()

    too_many = copy.deepcopy(fixture)
    too_many['mailboxes']['INBOX']['messages'] = [message(i) for i in range(1, 10002)]
    srv = t.Server(work, fixture=too_many)
    try:
        code, result = t.tool(srv, 'mail_brief')
        t.check('brief continuation: >10000 matching unseen remains unsupported, never skipped',
                code != 0 and no_cursor(result), result)
    finally:
        srv.stop()

    srv = t.Server(work, fixture=fixture)
    try:
        for folder in ('', 'x' * 4001, 'bad\r\nfolder'):
            offset = len(srv.log_lines())
            code, result = t.tool(srv, 'mail_brief', {'folder': folder})
            t.check('brief continuation: initial unseen cannot mint invalid folder binding', code != 0 and
                    no_cursor(result) and len(srv.log_lines()) == offset, result)
        invalid = [dict(token, version=2), dict(token, version='1'), dict(token, mode='arrivals'),
                   dict(token, high_uid='9'), dict(token, high_uid=9.0), dict(token, after_uid=-1),
                   dict(token, high_uid=4294967296), dict(token, after_uid=10),
                   dict(token, uidvalidity=0), dict(token, folder=''), dict(token, extra=True),
                   {k: v for k, v in token.items() if k != 'high_uid'}]
        for bad in invalid:
            offset = len(srv.log_lines())
            code, result = t.tool(srv, 'mail_brief', {'continuation': bad})
            t.check('brief continuation: malformed nested fields fail before IMAP', code != 0 and
                    no_cursor(result) and len(srv.log_lines()) == offset, result)
        for extra in ({'since_uid': 0}, {'folder': 'Elsewhere'}, {'uidvalidity': uidv + 1}):
            offset = len(srv.log_lines())
            code, result = t.tool(srv, 'mail_brief', {'continuation': token, **extra})
            t.check('brief continuation: conflicting top-level fields fail before IMAP', code != 0 and
                    no_cursor(result) and len(srv.log_lines()) == offset, result)
        raw = json.dumps({'continuation': token}).replace('"version": 1', '"version": 1, "version": 1')
        code, result = t.tool_text(srv, 'mail_brief', raw)
        t.check('brief continuation: duplicate nested member is rejected', code != 0 and no_cursor(result), result)
        for high in (10, 4294967295):
            offset = len(srv.log_lines())
            code, result = t.tool(srv, 'mail_brief', {'continuation': dict(token, after_uid=high, high_uid=high)})
            t.check('brief continuation: future or max highwater cannot wrap or search', code != 0 and
                    no_cursor(result) and not any(' UID SEARCH ' in x for x in srv.log_lines()[offset:]), result)
        offset = len(srv.log_lines())
        code, page = t.tool(srv, 'mail_brief', {'continuation': dict(token, after_uid=9)})
        t.check('brief continuation: empty range still verifies identity but never searches', code == 0 and
                page.get('messages') == [] and page.get('next_since_uid') == 9 and
                page.get('next_continuation') is None and
                sum(' EXAMINE ' in x for x in srv.log_lines()[offset:]) == 1 and
                not any(' UID SEARCH ' in x for x in srv.log_lines()[offset:]), page)
    finally:
        srv.stop()

    for mode in ('missing', 'empty-literal', 'empty-quoted', 'nil', 'budget', 'reset1', 'reset2', 'reset3'):
        changed = copy.deepcopy(fixture)
        if mode == 'missing':
            changed['mailboxes']['INBOX']['messages'][1]['omit_fetch_data'] = True
        elif mode.startswith('reset'):
            changed['examine_changes'] = [{'at': int(mode[-1]), 'uidvalidity': uidv + 1}]
        elif mode not in ('budget',):
            changed['mailboxes']['INBOX']['messages'][1].update(raw='X-Unrequested: synthetic', header_fetch_value=mode)
        srv = t.Server(work, fixture=changed)
        try:
            args = {'continuation': token, 'limit': 1}
            if mode == 'budget':
                args['max_response_bytes'] = 256
            code, result = t.tool(srv, 'mail_brief', args)
            if mode.startswith('empty-'):
                t.check(f'brief continuation: {mode} remains represented before cursor', code == 0 and
                        [m['uid'] for m in result.get('messages', [])] == [3] and
                        result.get('next_continuation') == dict(token, after_uid=3), result)
            else:
                t.check(f'brief continuation: {mode} emits no advancing cursor', code != 0 and no_cursor(result), result)
        finally:
            srv.stop()

    racing = copy.deepcopy(fixture)
    racing['mailboxes']['INBOX']['messages'] = [message(1), message(3), message(6, ['\\Seen']), message(7)]
    racing['uidnext_response'] = {'INBOX': 6}
    srv = t.Server(work, fixture=racing)
    try:
        code, first = t.tool(srv, 'mail_brief', {'limit': 1})
        code2, last = t.tool(srv, 'mail_brief', {'continuation': first.get('next_continuation')})
        code3, arrivals = t.tool(srv, 'mail_brief', {'since_uid': 5, 'uidvalidity': uidv})
        t.check('brief continuation: racing seen/unseen arrivals stay beyond original H until arrival poll',
                code == code2 == code3 == 0 and first.get('next_continuation') == dict(token, high_uid=5) and
                [m['uid'] for m in last.get('messages', [])] == [3] and last.get('next_since_uid') == 5 and
                [m['uid'] for m in arrivals.get('messages', [])] == [6, 7], (first, last, arrivals))
    finally:
        srv.stop()

    advanced_snapshot = copy.deepcopy(racing)
    advanced_snapshot.pop('uidnext_response')  # Current UIDNEXT is now8, token H stays5.
    srv = t.Server(work, fixture=advanced_snapshot)
    try:
        code, page = t.tool(srv, 'mail_brief', {'continuation': dict(token, high_uid=5)})
        searches = [x for x in srv.log_lines() if ' UID SEARCH ' in x]
        t.check('brief continuation: later UIDNEXT growth never refreshes original H', code == 0 and
                [m['uid'] for m in page.get('messages', [])] == [3] and page.get('next_since_uid') == 5 and
                page.get('next_continuation') is None and len(searches) == 1 and
                searches[0].endswith('UNSEEN UNDELETED UID 2:5'), (page, searches))
    finally:
        srv.stop()

    sparse = copy.deepcopy(fixture)
    sparse['mailboxes']['INBOX']['messages'] = [message(1, ['\\Seen']), message(4294967293), message(4294967294)]
    srv = t.Server(work, fixture=sparse)
    try:
        code, first = t.tool(srv, 'mail_brief', {'continuation': dict(token, after_uid=4294967292,
                                                                    high_uid=4294967294), 'limit': 1})
        code2, last = t.tool(srv, 'mail_brief', {'continuation': first.get('next_continuation')})
        t.check('brief continuation: sparse near-max UID interval progresses without wrap', code == code2 == 0 and
                [m['uid'] for m in first.get('messages', [])] == [4294967293] and
                [m['uid'] for m in last.get('messages', [])] == [4294967294] and
                last.get('next_since_uid') == 4294967294 and last.get('next_continuation') is None, (first, last))
    finally:
        srv.stop()

    changed_flags = copy.deepcopy(fixture)
    changed_flags['mailboxes']['INBOX']['messages'][1]['flags'] = ['\\Seen']
    changed_flags['mailboxes']['INBOX']['messages'][-1]['flags'] = []
    srv = t.Server(work, fixture=changed_flags)
    try:
        code, page = t.tool(srv, 'mail_brief', {'continuation': token})
        t.check('brief continuation: current flags ahead apply, behind-L unseen is not revisited', code == 0 and
                [m['uid'] for m in page.get('messages', [])] == [5, 9] and page.get('next_since_uid') == 9, page)
    finally:
        srv.stop()

    empty = copy.deepcopy(fixture)
    empty['mailboxes']['INBOX']['messages'] = []
    for high, next_uid in ((0, 1), (4294967294, 4294967295)):
        empty['uidnext_response'] = {'INBOX': next_uid}
        srv = t.Server(work, fixture=empty)
        try:
            code, page = t.tool(srv, 'mail_brief', {'continuation': dict(token, after_uid=high, high_uid=high)})
            t.check('brief continuation: zero/max-minus-one empty snapshots do not wrap', code == 0 and
                    page.get('next_since_uid') == high and page.get('messages') == [] and
                    not any(' UID SEARCH ' in x for x in srv.log_lines()), page)
        finally:
            srv.stop()
