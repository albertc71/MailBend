"""Deterministic metadata through every read tool, using only fake mail."""
import copy


def run(t, work):
    fixture = copy.deepcopy(t.FIX)
    msg = fixture['mailboxes']['INBOX']['messages'][0]
    msg['flags'] = ['\\Answered', '$Forwarded']
    metadata_headers = ('List-ID: Example <news.example.test>\r\n'
                        'Auto-Submitted: auto-generated\r\n'
                        'Precedence: bulk\r\n'
                        'List-Unsubscribe: <mailto:leave@example.test>,\r\n'
                        ' <https://example.test/leave?a=1,b=2>\r\n'
                        'List-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n')
    metadata_headers = 'X-Padding: ' + 'x' * 1600 + '\r\n' + metadata_headers
    msg['raw'] = msg['raw'].replace('\r\n\r\n', '\r\n' + metadata_headers + '\r\n', 1)
    expected = dict(list_id='Example <news.example.test>', auto_submitted='auto-generated',
                    bulk='list', unsubscribe=dict(mailto='mailto:leave@example.test',
                    https='https://example.test/leave?a=1,b=2', one_click=True),
                    answered=True, forwarded=True)
    srv = t.Server(work, fixture=fixture)
    try:
        before = srv.st()
        for tool, args in [('mail_search', {}), ('mail_get_new', {'since_uid': 0}),
                           ('mail_get_thread', {'uid': 1}),
                           ('mail_get', {'uid': 1}),
                           ('mail_get', {'uid': 1, 'max_bytes': 1024})]:
            code, result = t.tool(srv, tool, args, MAILBEND_TYPESAFE='0',
                                  MAILBEND_TYPESAFE_HELPER='/nonexistent-metadata-helper')
            messages = result.get('messages', [result])
            found = next((m for m in messages if m.get('uid') == 1), {})
            t.check(f'metadata: {tool} {args} agrees', code == 0 and
                    {k: found.get(k) for k in expected} == expected, result)
            if tool == 'mail_get_new':
                t.check('metadata: checkpoint remains complete',
                        result.get('next_since_uid') == 6 and not result.get('has_more'), result)
        code, result = t.tool(srv, 'mail_get_new', {'since_uid': 0, 'limit': 1,
                             'projection': 'metadata', 'max_response_bytes': 4096})
        t.check('metadata: bounded projection retains fields and checkpoint', code == 0 and
                result.get('next_since_uid') == 1 and result.get('has_more') and
                {k: result.get('messages', [{}])[0].get(k) for k in expected} == expected, result)
        t.check('metadata: reads preserve mailbox state', before == srv.st())
        lines = srv.log_lines()
        t.check('metadata: no read becomes a mutation', not any(
            ' SELECT ' in line or 'BODY[' in line or any(c in line for c in t.MUTATING_COMMANDS)
            for line in lines), lines)
        t.check('metadata: reads request one-click header', any(
            'LIST-UNSUBSCRIBE-POST' in line for line in lines), lines)
    finally:
        srv.stop()
