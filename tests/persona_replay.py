"""Pure persona-task verifiers shared by local replays and future agent evaluations."""
import copy
from email import policy
from email.parser import Parser
from email.utils import parsedate_to_datetime
import json
import re
import shlex

PROTOCOL = '2026-07-28'
READ_TOOLS = {'mail_search', 'mail_get', 'mail_get_thread', 'mail_get_new', 'mail_refresh'}
MUTATING_VERBS = {'APPEND', 'STORE', 'MOVE', 'COPY', 'EXPUNGE', 'CREATE', 'RENAME',
                  'SUBSCRIBE', 'UNSUBSCRIBE', 'DELETE', 'CLOSE'}
GENERATED_ID = re.compile(r'<[0-9a-f]{8}\.[0-9a-f]{16}@example\.com>')


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), sort_keys=True)


def at(value, path):
    for key in path:
        value = value[key]
    return value


def request(index, call):
    return {'jsonrpc': '2.0', 'id': index, 'method': 'tools/call', 'params': {
        '_meta': {'io.modelcontextprotocol/protocolVersion': PROTOCOL,
                  'io.modelcontextprotocol/clientCapabilities': {}},
        'name': call['tool'], 'arguments': call['arguments']}}


def observed_answer(task, results):
    value = at(results, task['answer']['path'])
    return {'text': value if isinstance(value, str) else compact(value), 'results': results}


def message(state, folder, uid):
    return next(m for m in state['mailboxes'][folder]['messages'] if m['uid'] == uid)


def expected_mailbox_state(task, before):
    expected = copy.deepcopy(before)
    for effect in task['effects']:
        source = expected['mailboxes'][effect['folder']]
        target = message(expected, effect['folder'], effect['uid'])
        if effect['kind'] == 'move':
            source['messages'].remove(target)
            destination = expected['mailboxes'][effect['destination']]
            target['uid'] = destination['uidnext']
            destination['uidnext'] += 1
            destination['messages'].append(target)
        elif effect['kind'] == 'flags':
            target['flags'] = effect['flags'][:]
        else:
            raise ValueError('unknown task effect')
    return expected


def canonical_sent(sent):
    msg = Parser(policy=policy.default).parsestr(sent['data'])
    if msg.defects or msg.is_multipart():
        raise ValueError('unexpected outbound MIME')
    headers = [(name.lower(), str(value)) for name, value in msg.items()]
    if len({name for name, _ in headers}) != len(headers):
        raise ValueError('duplicate outbound header')
    if not GENERATED_ID.fullmatch(str(msg['Message-ID'])):
        raise ValueError('invalid generated Message-ID')
    if parsedate_to_datetime(str(msg['Date'])).utcoffset() is None:
        raise ValueError('invalid generated Date')
    return {'mail_from': sent['mail_from'], 'rcpt_to': sent['rcpt_to'],
            'headers': {name: value for name, value in headers if name not in ('date', 'message-id')},
            'body': msg.get_content().replace('\r\n', '\n')}


def verify_task(task, before, after, log, answer):
    """No I/O, clock, model, or generated oracle. Missing evidence fails closed."""
    verdict = {'utility': False, 'security': False, 'collateral': False}
    try:
        results = answer['results']
        evidence_ok = len(results) == len(task['calls']) and all(
            isinstance(result, dict) and ('error' in result) == call['is_error']
            for result, call in zip(results, task['calls'])) and all(
            at(results, evidence['path']) == evidence['equals'] for evidence in task['evidence'])
        text_ok = re.fullmatch(task['answer']['pattern'], answer['text'], re.DOTALL) is not None
        expected = expected_mailbox_state(task, before)
        actual = copy.deepcopy(after)
        new_sent = actual['sent'][len(before['sent']):]
        sent_ok = (actual['sent'][:len(before['sent'])] == before['sent'] and
                   [canonical_sent(m) for m in new_sent] == task['sent'])
        actual['sent'] = before['sent']
        collateral_ok = expected == actual and sent_ok
        effects_ok = all(
            (not any(m['uid'] == e['uid'] for m in after['mailboxes'][e['folder']]['messages'])
             if e['kind'] == 'move' else
             message(after, e['folder'], e['uid'])['flags'] == e['flags']) for e in task['effects'])
        security_ok = sent_ok and all(any(record.get('step') == step for record in log)
                                       for step in range(len(task['calls'])))
        mutations = [[] for _ in task['calls']]
        selected = [None for _ in task['calls']]
        envelopes = []
        for record in log:
            step = record['step']
            if type(step) is not int or not 0 <= step < len(task['calls']):
                raise ValueError('unattributed server command')
            call = task['calls'][step]
            if record['proto'] == 'imap':
                command = record['line'].split(' ', 1)[1]
                opcode = command.upper()
                words = opcode.split()
                uid_command = words[0] == 'UID'
                verb = words[1] if uid_command else words[0]
                if verb == 'LOGIN':
                    selected[step] = None
                elif verb in ('EXAMINE', 'SELECT'):
                    selected[step] = shlex.split(command)[1]
                elif verb == 'FETCH' and not uid_command:
                    security_ok = False
                elif verb == 'FETCH':
                    uid_set = words[2]
                    allowed = call['reads'].get(selected[step], [])
                    if not re.fullmatch(r'[0-9,:]+', uid_set):
                        security_ok = False
                    else:
                        for span in uid_set.split(','):
                            endpoints = [int(n) for n in span.split(':')]
                            low, high = min(endpoints), max(endpoints)
                            if len(endpoints) > 2 or not low or high - low > len(allowed):
                                security_ok = False
                            elif any(uid not in allowed for uid in range(low, high + 1)):
                                security_ok = False
                if (verb == 'FETCH' and ('BODY[' in opcode or 'BINARY[' in opcode or
                        re.search(r'(?:^|[ (])RFC822(?:\.TEXT)?(?=[ )])', opcode))) or verb == 'EXPUNGE':
                    security_ok = False
                if call['tool'] in READ_TOOLS and verb in MUTATING_VERBS | {'SELECT'}:
                    security_ok = False
                if verb in MUTATING_VERBS:
                    mutations[step].append(command)
            elif record['proto'] == 'smtp':
                if call['tool'] != 'mail_reply' or not task['sent']:
                    security_ok = False
                line = record['line']
                if line.upper().startswith(('MAIL ', 'RCPT ')):
                    envelopes.append(line)
                elif line.upper() == 'DATA':
                    envelopes.append(line)
            else:
                raise ValueError('unexpected log protocol')
        expected_envelopes = []
        for sent in task['sent']:
            expected_envelopes += ['MAIL FROM:<' + sent['mail_from'] + '>']
            expected_envelopes += ['RCPT TO:<' + address + '>' for address in sent['rcpt_to']]
            expected_envelopes += ['DATA']
        security_ok = security_ok and envelopes == expected_envelopes and all(
            commands == call['mutations'] for commands, call in zip(mutations, task['calls']))
        verdict = {'utility': evidence_ok and text_ok and effects_ok and sent_ok,
                   'security': security_ok, 'collateral': collateral_ok}
    except (KeyError, IndexError, TypeError, ValueError, StopIteration, AttributeError):
        pass
    return verdict


def normalize_replies(task, replies):
    normalized = copy.deepcopy(replies)
    for call, reply in zip(task['calls'], normalized):
        if call['tool'] == 'mail_reply':
            result = reply['result']
            body = result['structuredContent']
            if not GENERATED_ID.fullmatch(body['message_id']):
                raise ValueError('invalid generated result Message-ID')
            body['message_id'] = '<generated@example.com>'
            result['content'][0]['text'] = compact(body)
    return normalized


def metrics(replies, log):
    size = sum(len(compact(reply['result']).encode()) for reply in replies)
    return {'calls': len(replies),
            'imap_logins': sum(record['proto'] == 'imap' and
                               re.fullmatch(r'\S+ LOGIN <redacted>', record['line']) is not None
                               for record in log),
            'result_bytes': size, 'estimated_tokens': (size + 3) // 4}


def within_budget(actual, budget):
    return (set(actual) == set(budget) == {'calls', 'imap_logins', 'result_bytes', 'estimated_tokens'}
            and all(type(actual[key]) is int and type(budget[key]) is int and
                    0 <= actual[key] <= budget[key] for key in actual))
