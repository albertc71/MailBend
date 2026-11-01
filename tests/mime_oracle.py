"""Independent checks of complete, synthetic MailBend composition bytes."""
import atexit
import base64
from email import policy
from email.parser import BytesParser
from email.utils import getaddresses
from functools import lru_cache
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote_to_bytes

ROOT = Path(__file__).resolve().parents[1]
ADDRESS_FIELDS = {'from', 'to', 'cc', 'bcc', 'reply-to', 'sender'}


def require(equal, message):
    if not equal:
        raise AssertionError(message)


def parse(raw):
    return BytesParser(policy=policy.default).parsebytes(raw)


def terminal_parts(message):
    # message/rfc822 is an attachment, not a multipart body to descend into.
    if message.get_content_maintype() != 'multipart':
        return [message]
    return [leaf for child in message.iter_parts() for leaf in terminal_parts(child)]


def header_value(name, value):
    if name in ADDRESS_FIELDS:
        return getaddresses([value])
    if name in {'in-reply-to', 'references', 'message-id', 'date'}:
        return ' '.join(value.split())
    return value


def compare(raw, observed):
    message = parse(raw)
    for field, expected_root in [('content_type', message.get_content_type()),
                                 ('disposition', message.get_content_disposition() or ''),
                                 ('charset', message.get_content_charset() or ''),
                                 ('boundary', message.get_boundary() or '')]:
        require(observed[field] == expected_root, 'root ' + field + ' disagrees')
    actual = [(entry['name'], header_value(entry['name'], entry['value']))
              for entry in observed['headers']]
    expected = [(name.lower(), header_value(name.lower(), str(value)))
                for name, value in message.items()]
    # MIME parameter formatting and date parsing have distinct representations.
    # Their semantics are checked below; Date is preserved as raw RFC field text.
    ignored = {'content-type', 'content-disposition', 'date'}
    require([(n, v) for n, v in actual if n not in ignored] ==
            [(n, v) for n, v in expected if n not in ignored],
            f'headers disagree: MailBend={actual!r}; Python={expected!r}')
    raw_dates = [' '.join(v.split()) for n, v in message.raw_items() if n.lower() == 'date']
    require([v for n, v in actual if n == 'date'] == raw_dates, 'Date field bytes changed')
    parts = terminal_parts(message)
    require(len(observed['parts']) == len(parts), 'MIME leaf count disagrees')
    for index, (got, part) in enumerate(zip(observed['parts'], parts)):
        label = f'part {index}'
        require(got['content_type'] == part.get_content_type(), label + ' media type disagrees')
        require(got['filename'] == (part.get_filename() or ''),
                label + f' filename disagrees: MailBend={got["filename"]!r}; Python={part.get_filename()!r}')
        require(got['disposition'] == (part.get_content_disposition() or ''), label + ' disposition disagrees')
        require(got['charset'].lower() == (part.get_content_charset() or ''), label + ' charset disagrees')
        body = base64.b64decode(got['data'], validate=True)
        if part.get_content_maintype() == 'text':
            require(got['text'] == part.get_content().replace('\r\n', '\n'), label + ' decoded text disagrees')
        if part.get_content_type() == 'message/rfc822':
            # Python returns a child object, not decoded bytes. Compare its parsed
            # semantics; exact enclosed bytes are separately checked against Draft.
            child = part.get_payload()[0]
            require(semantic_message(parse(body)) == semantic_message(child), label + ' enclosed message disagrees')
        else:
            require(body == part.get_payload(decode=True), label + ' decoded bytes disagree')
    return message


def semantic_message(message):
    return ([(n.lower(), v) for n, v in message.raw_items()],
            [(p.get_content_type(), p.get_filename(),
              semantic_message(p.get_payload()[0]) if p.get_content_type() == 'message/rfc822'
              else p.get_payload(decode=True)) for p in terminal_parts(message)])


def normalized_body(value):
    return value.replace('\r\n', '\n').replace('\r', '\n')


THREAD_EXPECTATIONS = {
    'Injection': ('<x@y>', ''),
    'Mixed': ('<p@x>', '<r1@x> <r2@x> <r3@x>'),
    'ThreadTokens': ('<a@x>', '<root@x> <a@x>'),
    'ReferenceTokens': ('', '<root@x> <a@x>'),
    'LongReferences': ('', '<root@x> ' + '<middle@x> ' * 87 + '<last1@x> <last2@x>'),
    'MalformedIds': ('<a@x>', ''),
    'ReferenceExact': ('', '<' + 'a' * 982 + '@x>'),
    'ReferenceOver': ('', ''),
    'ReferencesExact': ('', '<' + 'a' * 496 + '@x> <' + 'b' * 481 + '@x>'),
    'MandatoryOver': ('<reply@x>', ''),
    'IdGrammar': ('<ok@[127.0.0.1]> <ok@[IPv6:abcd::1]> <end@x>', ''),
}
TYPE_EXPECTATIONS = {
    'Injection': ['application/octet-stream'],
    'Mixed': ['application/pdf', 'application/octet-stream', 'application/octet-stream'],
    'BoundaryCollision': ['application/octet-stream'],
}


def check_filename_parameters(part, filename):
    literal = re.search(r'=\?.*?\?=', filename, re.S) is not None
    plain = not literal and len(filename) <= 200 and all(c == '\t' or ' ' <= c <= '~' for c in filename)
    for header, key in [('content-type', 'name'), ('content-disposition', 'filename')]:
        require(part.get_param(key, header=header) == filename, header + ' filename differs from input Draft')
        value = next(value for name, value in part.raw_items() if name.lower() == header)
        parameters = value.split(';\r\n ')[1:]
        if plain:
            quoted = filename.replace('\\', '\\\\').replace('"', '\\"')
            require(parameters == [key + '="' + quoted + '"'], 'short ASCII filename wire changed')
            continue
        fallback = ''.join(c if ' ' <= c <= '~' and c not in '"\\' else '_' for c in filename[:60])
        if literal:
            fallback = 'attachment'
        require(parameters and parameters[-1] == key + '="' + fallback + '"', 'ASCII filename fallback changed')
        pieces = []
        for index, parameter in enumerate(parameters[:-1]):
            prefix = key + '*' + str(index) + '*=' + ("utf-8''" if index == 0 else '')
            require(parameter.startswith(prefix), 'composed filename continuations must precede fallback in order')
            piece = parameter[len(prefix):]
            require(0 < len(piece) <= 50 and re.fullmatch(r"(?:[A-Za-z0-9!#$&+.^_`|~-]|%[0-9A-F]{2})+", piece),
                    'RFC 2231 filename piece split a percent token or exceeded its bound')
            pieces.append(piece)
        require(pieces and unquote_to_bytes(''.join(pieces)) == filename.encode('utf-8'),
                'RFC 2231 filename bytes differ from UTF-8 input Draft')
        require(all(len(parameter) + 1 <= 79 for parameter in parameters), 'filename parameter line exceeds bound')


def check_input(raw, message, draft, case_name):
    require(message.get_content_type() == ('multipart/mixed' if draft['attachments'] else 'text/plain'),
            'root media type differs from input Draft')
    require(str(message['Subject']) == draft['subject'], 'composed Subject differs from input Draft')
    for name in ('from', 'to', 'cc', 'bcc'):
        values = [draft[name]] if name == 'from' else draft[name]
        # getaddresses does not decode encoded words. Literal =?...?= names stay literal.
        expected = getaddresses(values)
        field = message[name]
        got = [(a.display_name, a.addr_spec) for a in field.addresses] if field else []
        require(got == expected, name + ' differs from input Draft')
    dates = [value for key, value in message.raw_items() if key.lower() == 'date']
    require(dates == [draft['date']], 'Date differs from input Draft')
    require(str(message['Message-ID']) == draft['message_id'], 'Message-ID differs from input Draft')
    wanted_ids = THREAD_EXPECTATIONS.get(case_name, (draft['in_reply_to'], draft['references']))
    for field, expected in zip(('In-Reply-To', 'References'), wanted_ids):
        require(' '.join(str(message.get(field, '')).split()) == expected, field + ' differs from reviewed expectation')
    leaves = terminal_parts(message)
    require(len(leaves) == len(draft['attachments']) + 1, 'input Draft part count differs')
    require(normalized_body(leaves[0].get_content()) == normalized_body(draft['text']), 'body differs from input Draft')
    types = TYPE_EXPECTATIONS.get(case_name, [a['content_type'].lower() for a in draft['attachments']])
    for part, attachment, content_type in zip(leaves[1:], draft['attachments'], types):
        require(part.get_content_type() == content_type, 'attachment type differs from reviewed expectation')
        require(part.get_filename() == attachment['filename'], 'filename differs from input Draft')
        check_filename_parameters(part, attachment['filename'])
        original = base64.b64decode(attachment['data'], validate=True)
        if content_type.startswith('text/'):
            charset = 'us-ascii' if original.isascii() else 'utf-8'
            try:
                original.decode('utf-8')
            except UnicodeDecodeError:
                charset = None
            require(part.get_content_charset() == charset, 'attachment charset differs from input bytes')
        if part.get_content_type() == 'message/rfc822':
            require(b'\r\n\r\n' + original + b'\r\n--' in raw, 'raw attached-message bytes changed')
        else:
            require(part.get_payload(decode=True) == original, 'attachment bytes differ from input Draft')


@lru_cache(maxsize=1)
def bend_executable():
    directory = tempfile.TemporaryDirectory(prefix='mailbend-mime-oracle-')
    atexit.register(directory.cleanup)
    executable = str(Path(directory.name) / 'mime-oracle')
    result = subprocess.run(['bend', str(ROOT / 'tests/mime-oracle.bend'), '-o', executable],
                            capture_output=True, timeout=240)
    require(result.returncode == 0, 'Bend MIME oracle compilation failed: '
            + result.stderr.decode(errors='replace')[-3000:] + result.stdout.decode(errors='replace')[-3000:])
    return executable


def bend_records(raws=None, cases=False):
    command = [bend_executable()]
    if cases:
        command += ['--cases']
    data = b'' if raws is None else b'\n'.join(base64.b64encode(raw) for raw in raws)
    process = subprocess.run(command, input=data, capture_output=True, timeout=240)
    require(process.returncode == 0, 'Bend MIME oracle failed: ' + process.stderr.decode(errors='replace')[-3000:]
            + process.stdout.decode(errors='replace')[-3000:])
    return [json.loads(line) for line in process.stdout.decode().split('\n') if line]


def check_registry():
    source = (ROOT / 'tests/composition-cases.bend').read_text()
    tags = re.findall(r'^  (\w+)\{\}$', source.split('def long_refs', 1)[0], re.M)
    listed = re.findall(r'(\w+)\{\}', source.split('def all()', 1)[1])
    require(tags and sorted(tags) == sorted(listed), 'every typed composition case must be exported exactly once')
    for path in (ROOT / 'tests').rglob('*.bend'):
        if path.name == 'composition-cases.bend':
            continue
        text = path.read_text()
        aliases = re.findall(r'import\s+\S*/mime\.bend\s+as\s+(\w+)', text)
        require(not any(re.search(r'\b' + alias + r'\.compose\s*\(', text) for alias in aliases),
                f'{path}: put composition inputs in composition-cases.bend')
    return tags


def check_python_runtime(check):
    first = base64.b64encode(('é' * 19).encode()).decode()
    last = base64.b64encode('é'.encode()).decode()
    raw = f'From: =?UTF-8?B?{first}?=\r\n =?UTF-8?B?{first}?=\r\n =?UTF-8?B?{last}?= <sender@example.invalid>\r\n\r\n'.encode()
    actual = parse(raw)['From'].addresses[0].display_name
    check('Python email oracle ignores adjacent encoded-word whitespace', actual == 'é' * 39,
          f'Python {sys.version.split()[0]} has CPython #128110; use Python 3.13.18 (CI pin) '
          'or another runtime containing the fix. For example, rerun with '
          '`uv run --python 3.13.18 --with jsonschema==4.26.0 python` instead of `python3`; '
          'decoded display name=' + repr(actual))


def check_unit_compositions(check):
    check_python_runtime(check)
    tags = check_registry()
    records = bend_records(cases=True)
    check('composition registry exports every case once',
          sorted(r['name'] for r in records) == sorted(tags))
    for record in records:
        try:
            raw = base64.b64decode(record['wire'], validate=True)
            message = compare(raw, record['parsed'])
            check_input(raw, message, record['input'], record['name'])
        except (AssertionError, ValueError) as error:
            check('independent composition ' + record['name'], False, str(error))
        else:
            check('independent composition ' + record['name'], True)


def check_captured(records, check):
    check_python_runtime(check)
    raws = list(dict.fromkeys(record['raw'].encode('latin-1') for record in records))
    controls = [b'Subject: chunk boundary\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n'
                + b'chunk data\r\n' * 7000 + '\u2028\u0085end'.encode(), b'Subject: final unterminated frame\r\n\r\nsecond']
    raws = controls + raws
    parsed = bend_records(raws)
    check('composition audit has one result per unique received wire', len(parsed) == len(raws))
    for index, (raw, observed) in enumerate(zip(raws, parsed)):
        label = f'stream control {index}' if index < len(controls) else f'independent received composition {index - len(controls)}'
        try:
            compare(raw, observed)
        except (AssertionError, ValueError) as error:
            check(label, False, str(error))
        else:
            check(label, True)


def self_test():
    """Known-good and broken observations prove each comparator is live."""
    import copy
    raw = (b'From: Sender <sender@example.invalid>\r\nSubject: literal\r\n'
           b'Content-Type: text/plain; charset=utf-8\r\n'
           b'Content-Disposition: attachment; filename=notes.txt\r\n\r\nhello')
    good = {'content_type': 'text/plain', 'disposition': 'attachment', 'charset': 'utf-8', 'boundary': '',
            'headers': [{'name': 'from', 'value': 'Sender <sender@example.invalid>'},
                        {'name': 'subject', 'value': 'literal'},
                        {'name': 'content-type', 'value': 'text/plain; charset=utf-8'},
                        {'name': 'content-disposition', 'value': 'attachment; filename=notes.txt'}],
            'parts': [{'content_type': 'text/plain', 'filename': 'notes.txt', 'disposition': 'attachment',
                       'charset': 'utf-8', 'text': 'hello', 'data': 'aGVsbG8='}]}
    compare(raw, good)
    mutations = []
    for field, value in [('content_type', 'multipart/alternative'), ('disposition', 'inline'),
                         ('charset', 'us-ascii'), ('boundary', 'wrong')]:
        wrong = copy.deepcopy(good)
        wrong[field] = value
        mutations.append(('root ' + field, wrong))
    wrong = copy.deepcopy(good)
    wrong['headers'][1]['value'] = 'changed'
    mutations.append(('header', wrong))
    wrong = copy.deepcopy(good)
    wrong['parts'] = []
    mutations.append(('part count', wrong))
    for field, value in [('filename', 'other.txt'), ('content_type', 'image/png'),
                         ('disposition', 'inline'), ('charset', 'us-ascii'),
                         ('text', 'wrong'), ('data', 'aGVsbGE=')]:
        wrong = copy.deepcopy(good)
        wrong['parts'][0][field] = value
        mutations.append((field, wrong))
    for name, wrong in mutations:
        try:
            compare(raw, wrong)
        except AssertionError:
            continue
        raise AssertionError('negative control was accepted: ' + name)
    return len(mutations)


def input_self_test():
    raw = (b'From: Sender <sender@example.invalid>\r\nTo: reader@example.invalid\r\n'
           b'Subject: original\r\nDate: Sat, 31 Oct 2026 12:00:00 +0000\r\n'
           b'Message-ID: <self@corpus.invalid>\r\nIn-Reply-To: <before@corpus.invalid>\r\n'
           b'References: <root@corpus.invalid>\r\nContent-Type: multipart/mixed; boundary=B\r\n\r\n'
           b'--B\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nhello\r\n'
           b'--B\r\nContent-Type: application/octet-stream;\r\n name="notes.bin"\r\n'
           b'Content-Disposition: attachment;\r\n filename="notes.bin"\r\n'
           b'Content-Transfer-Encoding: base64\r\n\r\naGk=\r\n--B--\r\n')
    draft = {'from': 'Sender <sender@example.invalid>', 'to': ['reader@example.invalid'], 'cc': [], 'bcc': [],
             'subject': 'original', 'date': 'Sat, 31 Oct 2026 12:00:00 +0000', 'message_id': '<self@corpus.invalid>',
             'in_reply_to': '<before@corpus.invalid>', 'references': '<root@corpus.invalid>', 'text': 'hello',
             'attachments': [{'filename': 'notes.bin', 'content_type': 'application/octet-stream', 'data': 'aGk='}]}
    check_input(raw, parse(raw), draft, 'control')
    changes = [(b'From: Sender', b'From: Other'), (b'To: reader@', b'To: other@'),
               (b'Subject: original', b'Subject: =?UTF-8?B?SGFja2Vk?='),
               (b'Date: Sat, 31 Oct', b'Date: Fri, 30 Oct'), (b'<self@', b'<other@'),
               (b'<before@', b'<other@'), (b'<root@', b'<other@'),
               (b'multipart/mixed', b'multipart/alternative'), (b'hello', b'other'),
               (b'\r\n name="notes.bin"', b'\r\n name="other.bin"'),
               (b'\r\n filename="notes.bin"', b'\r\n filename="other.bin"'),
               (b'application/octet-stream', b'image/png'),
               (b'aGk=', b'aG8='),
               (b'Subject: original', b'Cc: extra@example.invalid\r\nSubject: original'),
               (b'Subject: original', b'Bcc: extra@example.invalid\r\nSubject: original')]
    for before, after in changes:
        broken = raw.replace(before, after, 1)
        try:
            check_input(broken, parse(broken), draft, 'control')
        except AssertionError:
            continue
        raise AssertionError('input negative control was accepted: ' + repr(before))
    return len(changes)



def filename_self_test():
    filename = '=?UTF-8?B?SGk=?=.txt'
    wire = (b"Content-Type: application/octet-stream;\r\n name*0*=utf-8''%3D%3FUTF-8%3FB%3FSGk%3D%3F%3D.txt;\r\n name=\"attachment\"\r\n"
            b"Content-Disposition: attachment;\r\n filename*0*=utf-8''%3D%3FUTF-8%3FB%3FSGk%3D%3F%3D.txt;\r\n filename=\"attachment\"\r\n\r\nbody")
    check_filename_parameters(parse(wire), filename)
    mutations = [wire.replace(b'=\"attachment\"', b'=\"other\"'),
                 wire.replace(b'SGk', b'SGo'),
                 wire.replace(b"*0*=utf-8''%3D%3FUTF-8%3FB%3FSGk%3D%3F%3D.txt;\r\n name=\"attachment\"",
                              b'=\"=?UTF-8?B?SGk=?=.txt\"')]
    for broken in mutations:
        try:
            check_filename_parameters(parse(broken), filename)
        except AssertionError:
            continue
        raise AssertionError('literal filename negative control was accepted')
    return len(mutations)


def attached_self_test():
    import copy
    original = b'From: =?UTF-8?Q?Bob=0A=0Ahostile=0A?= <bob@example.invalid>\r\nSubject: original\r\n\r\nbody'
    raw = (b'Content-Type: multipart/mixed; boundary=B\r\n\r\n--B\r\n'
           b'Content-Type: message/rfc822\r\nContent-Disposition: attachment; filename=original.eml\r\n\r\n'
           + original + b'\r\n--B--\r\n')
    good = {'content_type': 'multipart/mixed', 'disposition': '', 'charset': '', 'boundary': 'B',
            'headers': [{'name': 'content-type', 'value': 'multipart/mixed; boundary=B'}],
            'parts': [{'content_type': 'message/rfc822', 'filename': 'original.eml',
                       'disposition': 'attachment', 'charset': '', 'text': '',
                       'data': base64.b64encode(original).decode()}]}
    compare(raw, good)
    for before, after in [(b'Bob', b'Eve'), (b'body', b'changed')]:
        wrong = copy.deepcopy(good)
        wrong['parts'][0]['data'] = base64.b64encode(original.replace(before, after)).decode()
        try:
            compare(raw, wrong)
        except AssertionError:
            continue
        raise AssertionError('attached-message mutation was accepted: ' + repr(before))
    return 2
