#!/usr/bin/env python3
"""Actual combined selected-MIME/projection contract checks, CLI and MCP."""
import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('combined_cases', root / 'tests/test-e2e.py')
t = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = t
spec.loader.exec_module(t)
with tempfile.TemporaryDirectory(prefix='mailbend-combined-', dir='/tmp') as work:
    subprocess.run(['sh', str(root / 'tests/gen-test-certs.sh'), str(Path(work) / 'certs')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for wire in ('cli', 'mcp'):
        os.environ['MAILBEND_TEST_MCP'] = '1' if wire == 'mcp' else '0'
        for media, payload in [('Text/Plain;charset=utf-8', ('Caf\u00e9 \U0001f600 "x"\n' * 500).encode()),
                               ('TEXT/HTML ;charset=utf-8', ('<p>\u65e5\u672c</p>' * 500).encode()),
                               ('application/octet-stream', bytes(range(256)) * 20)]:
            fixture = copy.deepcopy(t.FIX)
            fixture['mailboxes']['INBOX']['messages'][0]['raw'] = (
                f'Content-Type: {media}\r\nContent-Transfer-Encoding: base64\r\n\r\n'
                + base64.b64encode(payload).decode())
            srv = t.Server(work, fixture=fixture)
            try:
                args = dict(uid=1, uidvalidity=t.INBOX_VALIDITY, section='1')
                code, original = t.tool(srv, 'mail_get', args)
                t.check(f'{wire}/{media} selected source', code == 0 and original.get('complete') is True, original)
                if code:
                    continue
                before = srv.st()['mailboxes']
                for mode in ('full', 'text', 'html', 'metadata'):
                    main = media.split(';')[0].strip().lower()
                    keep = mode == 'full' or (mode == 'text' and main.startswith('text/') and main != 'text/html') or (mode == 'html' and main == 'text/html')
                    for budget in (0, 1000):
                        request = {**args, 'projection': mode}
                        if budget:
                            request['max_response_bytes'] = budget
                        code, value = t.tool(srv, 'mail_get', request)
                        label = f'{wire}/{media}/{mode}/{budget}'
                        t.check(label + ' success', code == 0, value)
                        if code:
                            continue
                        t.check(label + ' projection presence', ('content' in value) == keep, value)
                        t.check(label + ' source evidence', all(value.get(k) == original.get(k) for k in ('uid', 'uidvalidity', 'section', 'content_type', 'content_encoding', 'complete', 'scope', 'message_complete')), value)
                        notice = value['response']
                        shortened = keep and value['content'] != original['content']
                        t.check(label + ' representation completeness', notice['output_truncated'] == shortened and notice['content_complete'] == (keep and not shortened), notice)
                        if budget:
                            t.check(label + ' UTF8 budget', len(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()) <= budget, value)
                        if keep and value['content_encoding'] == 'base64':
                            decoded = base64.b64decode(value['content'], validate=True)
                            t.check(label + ' binary remains complete or empty', decoded in (payload, b''), len(decoded))
                        elif keep:
                            t.check(label + ' scalar prefix', original['content'].startswith(value['content']), value['content'])
                ts = t.TypeSafe(work)
                try:
                    code, annotated = t.tool(srv, 'mail_get',
                        {**args, 'projection': 'metadata', 'max_response_bytes': 6000},
                        **t.jev_env(ts, t.typesafe_key_file(work),
                                   MAILBEND_TYPESAFE_CONTENT='body',
                                   MAILBEND_TYPESAFE_ZERO_RETENTION='1'))
                    t.check(f'{wire}/{media} selected Jev survives metadata projection',
                        code == 0 and 'content' not in annotated and
                        annotated.get('jev', {}).get('status') == 'checked' and
                        annotated.get('scope') == 'selected_part' and
                        annotated.get('message_complete') is False and
                        annotated.get('response', {}).get('content_complete') is False, annotated)
                finally:
                    ts.stop()
                t.check(f'{wire}/{media} read-only flags', srv.st()['mailboxes'] == before)
            finally:
                srv.stop()
failed = [name for name, ok in t.results if not ok]
print(f'combined selected projections: {len(t.results) - len(failed)} passed, {len(failed)} failed')
sys.exit(bool(failed))
