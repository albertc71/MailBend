#!/usr/bin/env python3
"""Read reviewed synthetic .eml fixtures through mail_get; independently parse compositions."""
import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import mime_oracle as oracle

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / 'tests/corpus'
FIELDS = {'from', 'to', 'cc', 'reply_to', 'subject', 'date', 'message_id', 'in_reply_to',
          'references', 'text', 'html', 'html_available', 'attachments'}


def load_cases():
    paths = sorted(CORPUS.glob('*.eml'))
    oracle.require(paths, 'the MIME corpus is empty')
    oracle.require({p.stem for p in paths} == {p.stem for p in CORPUS.glob('*.json')},
                   'every .eml needs exactly one expected JSON file, and vice versa')
    cases = []
    for path in paths:
        data = json.loads(path.with_suffix('.json').read_text())
        label = path.name + ': '
        oracle.require(data['status'] in {'conformant', 'recovery', 'known_unsupported'}, label + 'unknown status')
        oracle.require(data['wire'] in {'valid', 'malformed'}, label + 'unknown wire classification')
        oracle.require(data['source']['kind'] == 'synthetic' and data['source']['license'] == 'MIT'
                       and data['source']['description'], label + 'missing synthetic provenance/license')
        oracle.require(data['references'] and all(u.startswith('https://') for u in data['references']),
                       label + 'missing primary references')
        values = [data['expected']]
        if data['status'] == 'known_unsupported':
            oracle.require(data['issues'] and data.get('diagnostic'), label + 'missing unsupported diagnostic/issue')
            oracle.require(data['known_wrong'] != data['expected'], label + 'known wrong must differ from desired')
            values.append(data['known_wrong'])
        else:
            oracle.require('known_wrong' not in data, label + 'unexpected known-wrong pin')
        oracle.require(data['status'] != 'conformant' or data['wire'] == 'valid', label + 'malformed cannot be conformant')
        oracle.require(data['status'] != 'recovery' or data['wire'] == 'malformed', label + 'recovery needs malformed input')
        for value in values:
            oracle.require(set(value) == FIELDS, label + 'projection fields missing or unexpected')
            oracle.require(all(isinstance(value[key], str) for key in FIELDS - {'html_available', 'attachments'}),
                           label + 'text/header fields must be strings')
            oracle.require(type(value['html_available']) is bool and value['html_available'] == bool(value['html']),
                           label + 'HTML presence is inconsistent')
            oracle.require(isinstance(value['attachments'], list), label + 'attachments must be a list')
            for attachment in value['attachments']:
                oracle.require(set(attachment) == {'filename', 'content_type', 'size'} and
                               isinstance(attachment['filename'], str) and isinstance(attachment['content_type'], str)
                               and type(attachment['size']) is int and attachment['size'] >= 0,
                               label + 'invalid attachment expectation')
        cases.append((path.stem, path.read_bytes(), data))
    return cases


def public_reads(cases, test, work):
    fixture = copy.deepcopy(test.FIX)
    inbox = fixture['mailboxes']['INBOX']
    inbox['messages'] = [{'uid': uid, 'flags': [], 'internaldate': '31-Oct-2026 12:00:00 +0000',
                          'raw': raw.decode('latin-1')}
                         for uid, (_, raw, _) in enumerate(cases, 1)]
    inbox['uidnext'] = len(cases) + 1
    counts = {'conformant': 0, 'recovery': 0, 'known_unsupported': 0}
    for mode in ('cli', 'mcp'):
        os.environ['MAILBEND_TEST_MCP'] = '1' if mode == 'mcp' else '0'
        server = test.Server(work, fixture=fixture)
        try:
            before = server.st()['mailboxes']['INBOX']
            for uid, (name, _, data) in enumerate(cases, 1):
                code, result = test.tool(server, 'mail_get', {'uid': uid, 'uidvalidity': inbox['uidvalidity']},
                                         MAILBEND_READ_ONLY='1')
                actual = {key: result.get(key) for key in FIELDS}
                label = f'{mode} corpus {name}'
                if data['status'] == 'known_unsupported':
                    if code == 0 and actual == data['known_wrong']:
                        counts['known_unsupported'] += 1
                        print(f'KNOWN-UNSUPPORTED {label}: {data["diagnostic"]} '
                              f'{", ".join(data["issues"])} (pin verified, not a conformance pass)')
                    else:
                        test.check(label + ' unsupported pin changed; review and update deliberately', False,
                                   {'exit': code, 'expected_current': data['known_wrong'], 'actual': actual,
                                    'now_matches_desired': actual == data['expected']})
                else:
                    ok = code == 0 and actual == data['expected']
                    test.check(label + (' conformance' if data['status'] == 'conformant' else ' malformed-input recovery'),
                               ok, {'exit': code, 'expected': data['expected'], 'actual': actual})
                    counts[data['status']] += int(ok)
                for selected in data.get('selected', []):
                    code, result = test.tool(server, 'mail_get', {'uid': uid, 'uidvalidity': inbox['uidvalidity'],
                                             'section': selected['section']}, MAILBEND_READ_ONLY='1')
                    if 'error' in selected:
                        test.check(label + ' selected transfer refusal', code != 0 and
                                   selected['error'] in result.get('error', ''), result)
                    else:
                        test.check(label + ' selected transfer content', code == 0 and result.get('complete') is True
                                   and result.get('content') == selected['content'], result)
                if 'reply' in data:
                    code, result = test.tool(server, 'mail_reply', {'uid': uid, 'uidvalidity': inbox['uidvalidity'],
                                             'body': 'My answer', 'as_draft': True})
                    draft = next((m['raw'] for m in server.st()['mailboxes']['Drafts']['messages']
                                  if m['uid'] == result.get('uid')), '')
                    message = oracle.parse(draft.encode('latin-1'))
                    expected = data['reply']
                    text = message.get_body(preferencelist=('plain',))
                    test.check(label + ' reply preserves literal subject, selected recipient and quoting',
                               code == 0 and str(message['Subject']) == expected['subject']
                               and str(message['To']) == expected['to']
                               and ' '.join(str(message['In-Reply-To']).split()) == expected['in_reply_to']
                               and ' '.join(str(message['References']).split()) == expected['references']
                               and text is not None
                               and text.get_content().splitlines() == expected['lines'], result)
            test.check(mode + ' corpus leaves original messages and flags unchanged',
                       server.st()['mailboxes']['INBOX'] == before)
            test.check(mode + ' corpus reads use EXAMINE and BODY.PEEK',
                       not any(' SELECT ' in line or ' BODY[' in line for line in server.log_lines()))
        finally:
            server.stop()
    print('corpus fixture outcomes (both CLI and MCP): ' + ', '.join(f'{n} {k}' for k, n in counts.items()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--validate-only', action='store_true', help='metadata and oracle controls only; no Bend or public reads')
    group.add_argument('--reads-only', action='store_true', help='diagnose public corpus reads only; not the full required check')
    group.add_argument('--compositions-only', action='store_true', help='diagnose named unit compositions only')
    args = parser.parse_args()
    cases = load_cases()
    count = (oracle.self_test() + oracle.input_self_test() + oracle.header_self_test()
             + oracle.attached_self_test() + oracle.filename_self_test()
             + oracle.composition_sites_self_test() + oracle.untransmitted_self_test())
    oracle.check_registry()
    oracle.check_composition_sites()
    subprocess.run([sys.executable, str(ROOT / 'tests/test-mime-capture.py')], check=True)
    print(f'corpus metadata: {len(cases)} synthetic MIT fixtures; oracle rejected {count} negative controls')
    if args.validate_only:
        return 0
    spec = importlib.util.spec_from_file_location('corpus_e2e', ROOT / 'tests/test-e2e.py')
    test = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = test
    spec.loader.exec_module(test)
    if not args.compositions_only:
        with tempfile.TemporaryDirectory(prefix='mailbend-corpus-') as work:
            subprocess.run(['sh', str(ROOT / 'tests/gen-test-certs.sh'), str(Path(work) / 'certs')],
                           check=True, capture_output=True)
            public_reads(cases, test, work)
    if not args.reads_only:
        oracle.check_unit_compositions(test.check)
        oracle.check_captured(test.composed_messages, test.check)
        oracle.check_untransmitted(test.untransmitted_messages, test.check)
        test.check('corpus composing calls were transmitted, replayed or refused before composing',
                   'unaudited' not in test.composition_outcomes, test.composition_outcomes)
    failed = [name for name, ok in test.results if not ok]
    print(f'MIME checks: {len(failed)} failed; known-unsupported fixture diagnostics are not conformance passes')
    return int(bool(failed))


if __name__ == '__main__':
    raise SystemExit(main())
