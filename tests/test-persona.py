#!/usr/bin/env python3
"""Replay synthetic mail tasks over modern MCP. No model or external service."""
import argparse
import copy
from email import policy
from email.parser import Parser
from email.utils import getaddresses, parsedate_to_datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from persona_replay import (READ_TOOLS, canonical_sent, compact, metrics, normalize_replies,
                            observed_answer, request, verify_task, within_budget)

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'tests/persona'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def check_corpus(generator, fixture, labels, tasks):
    data = generator.encoded(fixture)
    repeated, repeated_labels = generator.generate()
    require(generator.encoded(repeated) == data and repeated_labels == labels, 'seed not deterministic')
    other, _ = generator.generate(generator.SEED + 1)
    require(generator.encoded(other) != data, 'seed has no effect')
    manifest = json.loads((DATA / 'labels.json').read_text())
    require(manifest == {**labels, 'fixture_sha256': hashlib.sha256(data).hexdigest()}, 'corpus drift')
    all_ids = set()
    count = 0
    for name, box in fixture['mailboxes'].items():
        uids = set()
        for message in box['messages']:
            count += 1
            require(message['uid'] not in uids and message['uid'] > 0, 'duplicate UID')
            uids.add(message['uid'])
            raw = message['raw']
            require(re.search(r'(?<!\r)\n|\r(?!\n)', raw) is None, 'non-CRLF MIME')
            msg = Parser(policy=policy.default).parsestr(raw)
            require(not msg.defects and not any(p.defects for p in msg.walk()), 'invalid MIME')
            require(msg['Message-ID'] not in all_ids, 'duplicate Message-ID')
            all_ids.add(msg['Message-ID'])
            parsedate_to_datetime(msg['Date'])
            parsedate_to_datetime(message['internaldate'].replace('-', ' '))
            addresses = getaddresses([msg[name] for name in ('From', 'To', 'Cc') if msg[name]])
            require(addresses and all(re.fullmatch(r'[^@]+@example\.(com|net|org)', address)
                                      for _, address in addresses), 'non-example address')
    require(count == 500 and len(tasks) >= 20, 'corpus/task size')
    require({t['category'] for t in tasks} == {'find', 'read', 'reply', 'organise', 'attention', 'injection'},
            'missing task category')
    require(len({t['id'] for t in tasks}) == len(tasks), 'duplicate task ID')
    for task in tasks:
        require(task['budget_issue'] in (61, 66, 70, 72), 'missing budget issue')
        require(task['calls'] and task['prompt'] and task['answer']['pattern'], 'incomplete task')
        require(task['budget']['calls'] == len(task['calls']), 'call budget must catch one extra call')
        require(within_budget(task['budget'], task['budget']), 'malformed budget')
        for call in task['calls']:
            require(type(call['is_error']) is bool and isinstance(call['mutations'], list), 'malformed call')
    print(f'PASS deterministic 500-message corpus, MIME metadata, labels and {len(tasks)} task contracts')


def reject_mutations(task, before, after, log, answer, replies):
    def rejected(changed_before=before, changed_after=after, changed_log=log, changed_answer=answer):
        return not all(verify_task(task, changed_before, changed_after, changed_log, changed_answer).values())

    wrong = copy.deepcopy(answer)
    wrong['text'] = ''
    require(rejected(changed_answer=wrong), task['id'] + ': empty answer accepted')
    wrong = copy.deepcopy(answer)
    wrong['results'] = []
    require(rejected(changed_answer=wrong), task['id'] + ': omitted work accepted')
    wrong = copy.deepcopy(after)
    wrong['mailboxes']['INBOX']['messages'][-1]['flags'].append('\\Seen')
    require(rejected(changed_after=wrong), task['id'] + ': collateral flag accepted')
    wrong = copy.deepcopy(after)
    wrong['mailboxes']['Archive']['uidvalidity'] += 1
    require(rejected(changed_after=wrong), task['id'] + ': mailbox identity damage accepted')
    wrong = copy.deepcopy(after)
    wrong['subscribed'].append('Unexpected')
    require(rejected(changed_after=wrong), task['id'] + ': subscription damage accepted')
    wrong = copy.deepcopy(after)
    wrong['sent'].append({'mail_from': 'tester@example.com', 'rcpt_to': ['attacker@example.net'],
                          'data': ('From: tester@example.com\r\nTo: attacker@example.net\r\n'
                                   'Subject: Unrequested send\r\nDate: Thu, 01 Oct 2026 12:00:00 +0000\r\n'
                                   'Message-ID: <12345678.0123456789abcdef@example.com>\r\n'
                                   'MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n'
                                   'Content-Transfer-Encoding: 7bit\r\n\r\nUnrequested body.\r\n')})
    canonical_sent(wrong['sent'][-1])
    require(rejected(changed_after=wrong), task['id'] + ': unrequested send accepted')
    for effect in task['effects']:
        wrong = copy.deepcopy(after)
        if effect['kind'] == 'move':
            moved = wrong['mailboxes'][effect['destination']]['messages'][-1]
            moved['raw'] = 'Wrong target\r\n'
        else:
            next(m for m in wrong['mailboxes'][effect['folder']]['messages']
                 if m['uid'] == effect['uid'])['flags'] = ['unexpected']
        require(rejected(changed_after=wrong), task['id'] + ': wrong target/effect accepted')
    if task['sent']:
        wrong = copy.deepcopy(after)
        wrong['sent'][-1]['rcpt_to'] = ['attacker@example.net']
        require(rejected(changed_after=wrong), task['id'] + ': wrong recipient accepted')
        wrong = copy.deepcopy(after)
        wrong['sent'][-1]['data'] += 'Extra body\r\n'
        require(rejected(changed_after=wrong), task['id'] + ': changed reply body accepted')
    else:
        require(rejected(changed_log=log + [{'step': 0, 'proto': 'smtp', 'line': 'MAIL FROM:<tester@example.com>'}]),
                task['id'] + ': SMTP attempt accepted')
    require(rejected(changed_log=log + [
        {'step': 0, 'proto': 'imap', 'line': 'X EXAMINE "INBOX"'},
        {'step': 0, 'proto': 'imap', 'line': 'X UID FETCH 250 (UID BODY.PEEK[])'}]),
        task['id'] + ': unrelated body fetch accepted')
    require(rejected(changed_log=log + [
        {'step': 0, 'proto': 'imap', 'line': 'X EXAMINE "INBOX"'},
        {'step': 0, 'proto': 'imap', 'line': 'X uid fetch 250 (UID BODY.PEEK[])'}]),
        task['id'] + ': lower-case unrelated fetch accepted')
    for fetch in ('UID  FETCH 250', 'UID\tFETCH\t250'):
        require(rejected(changed_log=log + [
            {'step': 0, 'proto': 'imap', 'line': 'X EXAMINE "INBOX"'},
            {'step': 0, 'proto': 'imap', 'line': f'X {fetch} (UID BODY.PEEK[])'}]),
            task['id'] + ': whitespace variant unrelated fetch accepted')
    for destructive in ('DELETE "Archive"', 'CLOSE'):
        require(rejected(changed_log=log + [
            {'step': 0, 'proto': 'imap', 'line': 'X ' + destructive}]),
            task['id'] + ': unexpected destructive command accepted')
    require(rejected(changed_log=log + [
        {'step': 0, 'proto': 'imap', 'line': 'X FETCH 1 (BODY.PEEK[])'}]),
        task['id'] + ': non-UID fetch accepted')
    for nonpeek in ('BODY[]', 'RFC822', 'RFC822.TEXT', 'BINARY[]'):
        allowed = task['calls'][0]['reads']
        folder = next(iter(allowed), 'INBOX')
        uid = allowed.get(folder, [1])[0]
        require(rejected(changed_log=log + [
            {'step': 0, 'proto': 'imap', 'line': f'X EXAMINE "{folder}"'},
            {'step': 0, 'proto': 'imap', 'line': f'X UID FETCH {uid} (UID {nonpeek})'}]),
            task['id'] + ': non-PEEK fetch accepted')
    if task['id'] == 'read-stale-identity':
        require(rejected(changed_log=log + [
            {'step': 0, 'proto': 'imap', 'line': 'X EXAMINE "INBOX"'},
            {'step': 0, 'proto': 'imap', 'line': 'X UID FETCH 1 (UID BODY.PEEK[])'}]),
            task['id'] + ': stale UID fetched before refusal')
    require(rejected(changed_log=log + [{'step': 0, 'proto': 'imap', 'line': 'X UID EXPUNGE 1'}]),
            task['id'] + ': destructive command accepted')
    actual = metrics(replies, log)
    require(not within_budget(metrics(replies + [replies[-1]], log), task['budget']),
            task['id'] + ': extra call accepted')
    require(not within_budget(metrics(replies, log + [{'step': 0, 'proto': 'imap', 'line': 'X LOGIN <redacted>'}]),
                              task['budget']), task['id'] + ': extra login accepted')
    for key in ('result_bytes', 'estimated_tokens'):
        larger = {**actual, key: task['budget'][key] + 1}
        require(not within_budget(larger, task['budget']), task['id'] + ': excess ' + key + ' accepted')


def replay(t, task, fixture, work):
    srv = t.Server(work, fixture=fixture)
    clean = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR') if k in os.environ}
    clean.update({'BEND_NO_TELEMETRY': '1', 'MAILBEND_EMAIL': fixture['user'],
                  'MAILBEND_APP_PASSWORD': fixture['password'], 'MAILBEND_IMAP_HOST': 'localhost',
                  'MAILBEND_IMAP_PORT': srv.imap, 'MAILBEND_SMTP_HOST': 'localhost',
                  'MAILBEND_SMTP_PORT': srv.smtp, 'MAILBEND_CA_FILE': str(Path(work) / 'certs/ca.pem'),
                  'MAILBEND_TIMEOUT_MS': '10000', 'MAILBEND_SMTP_TLS_MODE': 'starttls',
                  'MAILBEND_TYPESAFE': '0', 'MAILBEND_SAVE_SENT': '0'})
    srv.env = lambda **over: {**clean, **over}
    replies, log, results = [], [], []
    try:
        before = srv.st()
        for index, call in enumerate(task['calls']):
            offset = len(srv.log_records())
            wire, code = t.mcp_bytes(srv, (compact(request(index, call)) + '\n').encode(), legacy=False)
            require(code == 0 and len(wire) == 1, task['id'] + ': MCP process or frame failure')
            reply = wire[0]
            require(reply.get('jsonrpc') == '2.0' and reply.get('id') == index and 'error' not in reply,
                    task['id'] + ': protocol error')
            result = reply['result']
            require(result['resultType'] == 'complete' and result['isError'] == call['is_error'],
                    task['id'] + ': unexpected tool outcome ' + compact(result))
            require(result['_meta']['io.modelcontextprotocol/serverInfo']['name'] == 'mailbend', 'wrong MCP server')
            body = result['structuredContent']
            require(json.loads(result['content'][0]['text']) == body, 'MCP content mismatch')
            errors = list(t.OUTPUT_VALIDATORS[call['tool']].iter_errors(body))
            require(not errors, str(errors))
            require(fixture['password'] not in compact(reply), 'synthetic password leaked')
            replies.append(reply)
            results.append(body)
            log.extend({**r, 'step': index} for r in srv.log_records()[offset:])
        after = srv.st()
        answer = observed_answer(task, results)
        inputs = compact([task, before, after, log, answer])
        verdict = verify_task(task, before, after, log, answer)
        require(inputs == compact([task, before, after, log, answer]), 'verifier changed its inputs')
        require(all(verdict.values()), task['id'] + ': verifier failure ' + compact(verdict) +
                '\nanswer=' + compact(answer) + '\nsent=' + compact(after['sent']) + '\nlog=' + compact(log))
        if task['sent']:
            require(results[-1]['message_id'] in after['sent'][-1]['data'], 'send ID does not match delivery')
        return before, after, log, answer, replies
    finally:
        srv.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--unit', action='store_true', help='Check corpus without running MailBend.')
    parser.add_argument('--record', action='store_true', help='Explicitly update golden replies and measured budgets.')
    parser.add_argument('--task', help='Run only this exact task ID.')
    parser.add_argument('--report', type=Path, help='Write measured budget table here, otherwise stdout.')
    args = parser.parse_args()
    require(not (args.unit and args.record), '--unit cannot record wire results')
    generator = load('persona_generator', ROOT / 'tools/generate-persona.py')
    fixture, labels = generator.generate()
    document = json.loads((DATA / 'tasks.json').read_text())
    tasks = document['tasks']
    check_corpus(generator, fixture, labels, tasks)
    if args.unit:
        return
    if args.task:
        tasks = [task for task in tasks if task['id'] == args.task]
        require(len(tasks) == 1, 'unknown task ID')
    require(all((ROOT / 'bin' / name).is_file() for name in
                ('mailbend-core', 'mailbend-stdio', 'mailbend-tls', 'mailbend-attach')), 'run scripts/install.sh first')
    t = load('persona_e2e', ROOT / 'tests/test-e2e.py')
    golden_path = DATA / 'golden.json'
    golden = json.loads(golden_path.read_text()) if golden_path.exists() else {}
    rows = []
    measurements = {}
    with tempfile.TemporaryDirectory(prefix='mailbend-persona-', dir='/tmp') as work:
        subprocess.run(['sh', str(ROOT / 'tests/gen-test-certs.sh'), str(Path(work) / 'certs')],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for task in tasks:
            before, after, log, answer, replies = replay(t, task, fixture, work)
            actual = metrics(replies, log)
            measurements[task['id']] = actual
            normalized = normalize_replies(task, replies)
            if args.record:
                task['budget'] = actual
                golden[task['id']] = normalized
            require(normalized == golden.get(task['id']), task['id'] + ': golden reply drift')
            require(within_budget(actual, task['budget']), task['id'] + ': budget exceeded ' + compact(actual))
            reject_mutations(task, before, after, log, answer, replies)
            rows.append(f"| {task['id']} | {actual['calls']} | {actual['imap_logins']} | "
                        f"{actual['result_bytes']} | {actual['estimated_tokens']} | #{task['budget_issue']} |")
            print('PASS', task['id'], compact(actual))
        if not args.task:
            original = next(task for task in tasks if not task['effects'] and not task['sent']
                            and all(call['tool'] in READ_TOOLS and not call['is_error']
                                    for call in task['calls']))
            regression = copy.deepcopy(original)
            regression['calls'].append(copy.deepcopy(regression['calls'][-1]))
            _, _, log, _, replies = replay(t, regression, fixture, work)
            actual = metrics(replies, log)
            baseline = measurements[original['id']]
            require(actual['calls'] == baseline['calls'] + 1 and
                    actual['imap_logins'] == baseline['imap_logins'] + 1 and
                    not within_budget(actual, original['budget']), 'actual extra-call regression accepted')
            print('PASS actual extra MCP read rejected by unchanged task budget', compact(actual))
    if args.record:
        (DATA / 'tasks.json').write_text(json.dumps(document, indent=2, ensure_ascii=False) + '\n')
        golden_path.write_text(json.dumps(golden, indent=2, ensure_ascii=False, sort_keys=True) + '\n')
    table = ('# Persona replay budgets\n\n'
             'Measured local modern MCP replies, not an LLM evaluation. Tokens are an estimate of '
             'ceil(result UTF-8 bytes / 4), not tokenizer counts. Bytes include the complete result '
             'envelope and both content representations. No timing or model-efficiency claim.\n\n'
             '| Task | Tool calls | IMAP logins | Result bytes | Estimated tokens | Budget issue |\n'
             '| --- | ---: | ---: | ---: | ---: | --- |\n' + '\n'.join(rows) + '\n')
    if args.report:
        args.report.write_text(table)
    else:
        print(table)


if __name__ == '__main__':
    main()
