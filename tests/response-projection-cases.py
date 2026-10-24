import copy
import json
import subprocess


def run(t, work):
    """Synthetic byte/character measurements; no tokenizer or token-saving claim."""
    text = ('Caf\u00e9 \u65e5\u672c \U0001f600 "quoted" \\ history\r\n> older message\r\n' * 100)
    html = '<p>' + text + '</p><a href="https://example.com">link</a>'
    def part(kind, body):
        return (f'Content-Type: text/{kind}; charset=utf-8\r\n'
                'Content-Transfer-Encoding: base64\r\n\r\n' + t.base64.b64encode(body.encode()).decode())
    variants = {'plain': part('plain', text), 'html': part('html', html),
                'multipart': ('Content-Type: multipart/alternative; boundary=b\r\n\r\n--b\r\n' +
                              part('plain', text) + '\r\n--b\r\n' + part('html', html) + '\r\n--b--\r\n')}
    for name, raw in variants.items():
        fixture = copy.deepcopy(t.FIX)
        fixture['mailboxes']['INBOX']['messages'][0]['raw'] = raw
        srv = t.Server(work, fixture=fixture)
        try:
            before = srv.st()['mailboxes']
            c, original = t.tool(srv, 'mail_get', {'uid': 1})
            t.check(f'projection {name}: legacy default', c == 0 and 'text' in original and
                    'html' in original and 'response' not in original, original)
            baseline = t.outputs[-2].strip()
            print('MEASURE', name, 'default', len(baseline.encode()), len(baseline))
            code, selected = t.tool(srv, 'mail_get', {'uid': 1, 'projection': 'text'})
            t.check(f'projection {name}: selection without budget is unbounded', code == 0 and
                    selected.get('text') == original['text'] and 'html' not in selected and
                    selected.get('response', {}).get('max_bytes') == 0 and
                    selected['response']['output_truncated'] is False, selected)
            for mode in ('full', 'text', 'html', 'metadata'):
                args = {'uid': 1, 'projection': mode, 'max_response_bytes': 1200}
                p = subprocess.run([t.LAUNCHER, 'call', 'mail_get', json.dumps(args)],
                                   capture_output=True, text=True, env=srv.env(), timeout=120)
                t.outputs.extend([p.stdout, p.stderr])
                line = p.stdout.strip()
                r = json.loads(line)
                t.check(f'projection {name}/{mode}: byte budget', p.returncode == 0 and
                        len(line.encode()) <= 1200, r)
                if p.returncode:
                    continue
                t.check(f'projection {name}/{mode}: protected metadata',
                        {k: v for k, v in r.items() if k not in ('text', 'html', 'response')} ==
                        {k: v for k, v in original.items() if k not in ('text', 'html')}, r)
                t.check(f'projection {name}/{mode}: selection',
                        ('text' in r) == (mode in ('full', 'text')) and
                        ('html' in r) == (mode in ('full', 'html')), r)
                cut = any(k in r and r[k] != original[k] for k in ('text', 'html'))
                t.check(f'projection {name}/{mode}: scalar prefixes and completeness',
                        all(original[k].startswith(r[k]) and '\ufffd' not in r[k]
                            for k in ('text', 'html') if k in r) and
                        r['response']['output_truncated'] == cut and r['truncated'] is False, r)
                request = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                           'params': {'name': 'mail_get', 'arguments': args}}
                m = subprocess.run([t.LAUNCHER, 'mcp'], input=json.dumps(request) + '\n',
                                   capture_output=True, text=True, env=srv.env(), timeout=120)
                t.outputs.extend([m.stdout, m.stderr])
                inner = json.loads(m.stdout)['result']['content'][0]['text']
                t.check(f'projection {name}/{mode}: MCP/CLI parity', json.loads(inner) == r and
                        len(inner.encode()) <= 1200)
                print('MEASURE', name, mode, len(line.encode()), len(line), len(m.stdout.encode()))
            c, r = t.tool(srv, 'mail_get', {'uid': 1, 'projection': 'metadata',
                                          'max_bytes': 1024, 'max_response_bytes': 1200})
            t.check(f'projection {name}: fetched truncation survives', c == 0 and r.get('truncated') is True, r)
            c, r = t.tool(srv, 'mail_get', {'uid': 1, 'max_response_bytes': 1})
            t.check(f'projection {name}: impossible budget rejected', c != 0 and
                    'too small' in r.get('error', '') and 'retry' in r['error'], r)
            t.check(f'projection {name}: mailbox unchanged', srv.st()['mailboxes'] == before)
        finally:
            srv.stop()
    srv = t.Server(work)
    try:
        for invalid in ({'projection': 'jsonpath'}, {'max_response_bytes': 0},
                        {'max_response_bytes': -1}, {'max_response_bytes': 16777217},
                        {'max_response_bytes': 4294967296}):
            before = len(srv.log_records())
            code, error = t.tool(srv, 'mail_get', dict(uid=1, **invalid))
            t.check('projection: invalid argument refused before connecting',
                    code != 0 and 'error' in error and len(srv.log_records()) == before, error)
        c, r = t.tool(srv, 'mail_get_new', {'max_response_bytes': 800})
        t.check('projection cursor: rejected page never advances', c != 0 and
                'next_since_uid' not in r and 'same checkpoint' in r.get('error', ''), r)
        since, validity, got = 0, 0, []
        for _ in range(10):
            c, r = t.tool(srv, 'mail_get_new', {'since_uid': since, 'uidvalidity': validity,
                                              'limit': 1, 'max_response_bytes': 1500})
            t.check('projection cursor: bounded page', c == 0, r)
            if c:
                break
            got.extend(m['uid'] for m in r['messages'])
            since, validity = r['next_since_uid'], r['uidvalidity']
            if not r['has_more']:
                break
        t.check('projection cursor: all arrivals retrieved', got == [1, 2, 3, 4, 5, 6], got)
        c, r = t.tool(srv, 'mail_get_new', {'since_uid': since, 'uidvalidity': 1,
                                          'max_response_bytes': 800})
        t.check('projection cursor: reset retained', c == 0 and r.get('uidvalidity_changed') is True
                and r.get('next_since_uid') == 0 and r.get('has_more') is True, r)
    finally:
        srv.stop()
