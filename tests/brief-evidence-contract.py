#!/usr/bin/env python3
"""Guard one-time classification preparation across the production brief flow.

This source contract is run from brief-cases.py by required CLI and MCP CI.
It counts classification call sites, not unrelated summary/annotation parsing,
and is not a runtime cost proof. Negative controls must break this contract.
"""
from collections import Counter
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def stripped(source):
    # Ignore strings and comments before looking for calls. Preserve newlines so
    # definition boundaries cannot be supplied by a comment or string literal.
    return re.sub(r'"(?:\\.|[^"\\])*"|#[^\n]*',
                  lambda m: re.sub(r'[^\n]', ' ', m.group()), source)


def definitions(source):
    clean = stripped(source)
    starts = list(re.finditer(r'^def ([\w.]+)\(', clean, re.M))
    return {m.group(1): clean[m.end():starts[i + 1].start() if i + 1 < len(starts) else len(clean)]
            for i, m in enumerate(starts)}


def calls(body):
    return Counter(re.findall(r'\b([A-Za-z_][\w.]*)\s*\(', body))


def verify(brief, tools):
    b, t = definitions(brief), definitions(tools)
    def count(defs, name, target, expected):
        require(calls(defs[name])[target] == expected, f'{name}: expected {expected} {target} call(s)')

    require(sum(calls(body)['M.headers'] for body in b.values()) == 1,
            'classification module must have one M.headers call site')
    count(b, 'evidence', 'M.headers', 1)
    count(b, 'evidence', 'classification_fields', 1)
    require(sum(calls(body)['evidence'] for body in b.values()) == 1,
            'classification evidence must be acquired only in prepare.complete')
    count(b, 'prepare.complete', 'evidence', 1)
    count(b, 'prepare', 'prepare.complete', 1)
    count(b, 'prepare_all', 'prepare', 1)
    count(b, 'prepare_all', 'prepare_all', 1)
    count(b, 'prepare.fields', 'fields_bytes', 1)
    count(b, 'prepare.fields', 'sender.small', 1)
    count(b, 'item', 'prepare', 1)
    count(b, 'item', 'prepared_item', 1)
    count(b, 'items', 'prepare_all', 1)
    count(b, 'items', 'prepared_items', 1)

    # Every local function reachable after preparation must remain free of
    # preparation, raw-message adapters and evidence parsing.
    pending = ['senders', 'sender', 'prepared_items', 'prepared_item']
    visited = set()
    forbidden = {'evidence', 'M.headers', 'prepare', 'prepare_all',
                 'prepare.complete', 'prepare.fields', 'item', 'items'}
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        visited.add(name)
        outgoing = calls(b[name])
        require(not forbidden.intersection(outgoing), f'{name}: reparses prepared evidence')
        pending.extend(c for c in outgoing if c in b)

    complete = re.sub(r'\s+', ' ', b['prepare.complete'])
    require(re.search(r'case False\{\}: Prepared\{m, \[\], False\{\}, None\{\}\} '
                      r'case True\{\}: prepare.fields\(m, evidence\(hs\)\)', complete),
            'unterminated headers must bypass the classification parse')
    prepared_fields = re.sub(r'\s+', ' ', b['prepare.fields'])
    require('Prepared{m, Bool.pick(List<&2, M.Hdr>, small, fields, []), '
            'small, sender.small(small, fields)}' in prepared_fields,
            'prepare.fields must retain the original message but discard invalid parsed fields')

    for target, owner in [('Brief.prepare_all', 'brief_contacts'), ('Brief.senders', 'brief_contacts'),
                          ('Brief.prepared_items', 'brief_output')]:
        require(sum(calls(body)[target] for body in t.values()) == 1,
                f'Tools must call {target} exactly once')
        count(t, owner, target, 1)
    require(not any(calls(body)['Brief.item'] or calls(body)['Brief.items'] or
                    calls(body)['Brief.evidence'] or calls(body)['Brief.prepare']
                    for body in t.values()), 'Tools must not rebuild classification evidence')
    contacts = re.sub(r'\s+', ' ', t['brief_contacts'])
    require('Brief.prepare_all(ms)' in contacts and 'Brief.senders(evidence)' in contacts and
            'PreparedBriefPage{p, evidence, senders}' in contacts,
            'brief_contacts must retain the same prepared messages and sender set')
    output = re.sub(r'\s+', ' ', t['brief_output'])
    require('PreparedBriefPage{p, evidence, +senders} = prepared' in output and
            'BriefPage{+folder, +uidv, +next, +more, +window, ms} = p' in output and
            'Brief.prepared_items(evidence, cs, allowed, String.to_lower(me))' in output and
            output.rstrip().endswith(']), ms}'),
            'brief_output must classify cached evidence and retain original Listed messages')
    for name, routes in {
        'brief_contacts.if': {'brief_output': 1, 'brief_roles': 1},
        'brief_roles': {'brief_output': 1, 'brief_sent_role': 1},
        'brief_sent_role': {'brief_output': 3},
    }.items():
        body = re.sub(r'\s+', ' ', t[name])
        require('p: PreparedBriefPage' in body and 'PreparedBriefPage{' not in body,
                f'{name}: must carry the prepared page unchanged')
        for route, expected in routes.items():
            count(t, name, route, expected)
            require(len(re.findall(r'\b' + re.escape(route) + r'\((?:(?:fs|r), )?p,', body)) == expected,
                    f'{name}: {route} must receive the same prepared page')


def run():
    brief = (ROOT / 'src/brief.bend').read_text(encoding='utf-8')
    tools = (ROOT / 'src/tools.bend').read_text(encoding='utf-8')
    verify(brief, tools)
    mutants = [
        ('reparse sender', brief.replace('  a\n\ndef senders.put(',
            '  sender.small(True{}, evidence("From: other@x\\r\\n\\r\\n"))\n\ndef senders.put('), tools),
        ('reparse items', brief.replace('      +b = bulk(fields)',
            '      +fields = evidence("From: other@x\\r\\n\\r\\n")\n      +b = bulk(fields)'), tools),
        ('reprepare output', brief, tools.replace(
            'Brief.prepared_items(evidence, cs, allowed, String.to_lower(me))',
            'Brief.items(ms, cs, allowed, String.to_lower(me))')),
        ('reprepare eligibility', brief, tools.replace('Brief.senders(evidence)',
            'Brief.senders(Brief.prepare_all(ms))')),
        ('discard prepared role page', brief, tools.replace(
            'brief_sent_role(fs, p, me, since, now)',
            'brief_sent_role(fs, PreparedBriefPage{p, [], []}, me, since, now)')),
    ]
    for name, changed_brief, changed_tools in mutants:
        require((changed_brief, changed_tools) != (brief, tools), f'{name}: mutation target moved')
        try:
            verify(changed_brief, changed_tools)
        except AssertionError:
            pass
        else:
            raise AssertionError(f'{name}: regression guard accepted the mutation')
    verify(brief, tools)
    return len(mutants)


if __name__ == '__main__':
    print(f'PASS prepared brief classification contract and {run()} rejected mutations')
