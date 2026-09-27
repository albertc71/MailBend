#!/usr/bin/env python3
"""A fake IMAP+SMTP server over TLS, used to exercise mailbend-tls (and the
Bend core above it) without touching a real mail account.

Usage:
    python3 fake_mail_server.py --certdir DIR --fixture FILE --state FILE \\
        --log FILE [--caps MOVE,UIDPLUS,SPECIAL-USE,IDLE] [--no-starttls] \\
        [--cert-name server] [--silent-port]

Binds IMAP (implicit TLS) and SMTP (STARTTLS, unless --no-starttls) on
127.0.0.1 with OS-assigned ports, prints one line

    READY imap=<port> smtp=<port> [silent=<port>]

and then serves until it receives SIGTERM/SIGINT. Every client command is
logged to --log as JSONL, and the mailbox/sent state is written to --state
after every mutation (see State.save below for the exact shape).

This file speaks just enough of IMAP4rev1 and ESMTP to drive the MailBend
transport and Bend parser; it is not a general-purpose mail server.
"""
import argparse
import base64
import json
import os
import re
import signal
import socket
import ssl
import sys
import threading
import time
from datetime import datetime, timezone
from email.header import decode_header

# --------------------------------------------------------------------------
# Modified UTF-7 (RFC 3501 5.1.3), used for IMAP mailbox names on the wire.
# --------------------------------------------------------------------------


def mutf7_encode(name: str) -> str:
    """Encodes a mailbox name (unicode) to modified UTF-7 (ASCII str)."""
    out = []
    i, n = 0, len(name)
    while i < n:
        c = name[i]
        if 0x20 <= ord(c) <= 0x7E and c != '&':
            out.append(c)
            i += 1
        elif c == '&':
            out.append('&-')
            i += 1
        else:
            j = i
            while j < n and not (0x20 <= ord(name[j]) <= 0x7E):
                j += 1
            chunk = name[i:j].encode('utf-16-be')
            b64 = base64.b64encode(chunk).decode('ascii').rstrip('=').replace('/', ',')
            out.append('&' + b64 + '-')
            i = j
    return ''.join(out)


def mutf7_decode(wire: str) -> str:
    """Decodes a modified-UTF-7 ASCII string back to a unicode mailbox name."""
    out = []
    i, n = 0, len(wire)
    while i < n:
        c = wire[i]
        if c != '&':
            out.append(c)
            i += 1
            continue
        j = i + 1
        if j < n and wire[j] == '-':
            out.append('&')
            i = j + 1
            continue
        k = j
        while k < n and wire[k] != '-':
            k += 1
        b64 = wire[j:k].replace(',', '/')
        b64 += '=' * (-len(b64) % 4)
        try:
            out.append(base64.b64decode(b64).decode('utf-16-be'))
        except Exception:
            out.append(wire[i:k])
        i = k + 1 if k < n else k
    return ''.join(out)


# --------------------------------------------------------------------------
# Small exceptions used to control the per-connection command loop.
# --------------------------------------------------------------------------


class ConnectionClosed(Exception):
    """The peer closed the connection (cleanly or otherwise)."""


class ProtocolError(Exception):
    """The peer sent something that does not fit the wire grammar."""


class CommandAborted(Exception):
    """A command was rejected before its literal was requested/read."""


# --------------------------------------------------------------------------
# Buffered line/byte reader shared by IMAP and SMTP, over a plain or TLS
# socket (both expose recv()/sendall()).
# --------------------------------------------------------------------------


class Conn:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b''

    def _fill(self):
        try:
            chunk = self.sock.recv(65536)
        except (OSError, ValueError):
            raise ConnectionClosed()
        if not chunk:
            raise ConnectionClosed()
        self.buf += chunk

    def readline(self):
        """Returns one line including its trailing \\n, or None at a clean EOF."""
        while b'\n' not in self.buf:
            try:
                self._fill()
            except ConnectionClosed:
                if self.buf:
                    raise ProtocolError('connection closed mid-line')
                return None
        idx = self.buf.index(b'\n')
        line, self.buf = self.buf[:idx + 1], self.buf[idx + 1:]
        return line

    def readexact(self, n):
        while len(self.buf) < n:
            self._fill()
        data, self.buf = self.buf[:n], self.buf[n:]
        return data

    def write(self, data: bytes):
        try:
            self.sock.sendall(data)
        except (OSError, ValueError):
            raise ConnectionClosed()


# --------------------------------------------------------------------------
# Shared mutable state: mailboxes/messages/sent, guarded by one lock and
# persisted to --state after every mutation.
# --------------------------------------------------------------------------


class State:
    def __init__(self, fixture: dict, state_path: str):
        self.lock = threading.RLock()
        self.state_path = state_path
        self.echo_login = False
        self.lowercase_codes = False
        self.special_on_request = False
        self.special_return_fails = False
        mailboxes = {}
        for name, mb in fixture['mailboxes'].items():
            messages = [dict(m) for m in mb.get('messages', [])]
            uidnext = max([m['uid'] for m in messages], default=0) + 1
            mailboxes[name] = {
                'uidvalidity': mb['uidvalidity'],
                'special': list(mb.get('special', [])),
                'messages': messages,
                'uidnext': uidnext,
            }
        self.data = {
            'user': fixture['user'],
            'password': fixture['password'],
            'mailboxes': mailboxes,
            'sent': [],
        }
        self.save()

    def save(self):
        """Atomically (write-temp + rename) persists the full current state."""
        tmp = self.state_path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(self.data, f, ensure_ascii=False, indent=1)
        os.replace(tmp, self.state_path)


class Logger:
    def __init__(self, path: str):
        self.lock = threading.Lock()
        self.path = path
        open(path, 'w', encoding='utf-8').close()

    def log(self, proto: str, line: str):
        with self.lock:
            with open(self.path, 'a', encoding='utf-8') as f:
                f.write(json.dumps({'proto': proto, 'line': line}, ensure_ascii=False) + '\n')


# --------------------------------------------------------------------------
# IMAP wire tokenizer: builds a tree of atoms (bytes), quoted strings
# (bytes, unescaped) and parenthesized lists (python lists), with literal
# content spliced in as a single already-resolved bytes token.
# --------------------------------------------------------------------------


class Tokenizer:
    def __init__(self):
        self.stack = [[]]

    def feed_text(self, data: bytes):
        i, n = 0, len(data)
        while i < n:
            c = data[i]
            if c in (0x20, 0x0D, 0x0A):
                i += 1
                continue
            if c == 0x28:  # '('
                new = []
                self.stack[-1].append(new)
                self.stack.append(new)
                i += 1
                continue
            if c == 0x29:  # ')'
                if len(self.stack) > 1:
                    self.stack.pop()
                i += 1
                continue
            if c == 0x22:  # '"'
                j = i + 1
                out = bytearray()
                while j < n and data[j] != 0x22:
                    if data[j] == 0x5C and j + 1 < n:  # backslash escape
                        j += 1
                    out.append(data[j])
                    j += 1
                self.stack[-1].append(bytes(out))
                i = j + 1
                continue
            j = i
            while j < n and data[j] not in (0x20, 0x28, 0x29, 0x0D, 0x0A):
                j += 1
            self.stack[-1].append(data[i:j])
            i = j

    def feed_literal(self, data: bytes):
        self.stack[-1].append(data)


def astring_val(tok) -> str:
    return tok.decode('latin-1') if isinstance(tok, bytes) else ''


def imap_quote(s: str) -> str:
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


LIT_RE = re.compile(rb'\{(\d+)\+?\}\r\n$')


# --------------------------------------------------------------------------
# UID sets, search predicates, and header/body section helpers.
# --------------------------------------------------------------------------


def parse_uid_set(spec, uids_sorted):
    if spec is None or not uids_sorted:
        return []
    highest = uids_sorted[-1]
    existing = set(uids_sorted)
    result = set()
    for part in spec.split(','):
        part = part.strip()
        if not part:
            continue
        if ':' in part:
            a_s, b_s = part.split(':', 1)
            a = highest if a_s == '*' else int(a_s)
            b = highest if b_s == '*' else int(b_s)
            lo, hi = (a, b) if a <= b else (b, a)
            for u in uids_sorted:
                if lo <= u <= hi:
                    result.add(u)
        else:
            v = highest if part == '*' else int(part)
            if v in existing:
                result.add(v)
    return sorted(result)


def split_header_lines(header_block: str):
    """Splits a raw header block (ending in the blank line) into logical
    header lines, each keeping any folded (indented) continuation lines."""
    text = header_block[:-4] if header_block.endswith('\r\n\r\n') else header_block.rstrip('\r\n')
    if not text:
        return []
    merged = []
    for ln in text.split('\r\n'):
        if ln and ln[0] in (' ', '\t') and merged:
            merged[-1] += '\r\n' + ln
        else:
            merged.append(ln)
    return merged


def to_unicode(s: str) -> str:
    """Our 'raw'/wire strings are latin-1-per-byte (one char per byte). A
    search needle or a message header/body may actually hold UTF-8 bytes in
    that form; decoding to real Unicode before case-folding avoids corrupting
    multi-byte sequences (naively .lower()-ing a mojibake string mismatches
    a leading UTF-8 byte's case fold against its unrelated Latin-1 letter,
    which changes its byte value while continuation bytes stay put)."""
    try:
        return s.encode('latin-1').decode('utf-8')
    except (UnicodeDecodeError, UnicodeEncodeError):
        return s


def header_body_split(raw: str):
    sep = raw.find('\r\n\r\n')
    if sep == -1:
        return raw + '\r\n\r\n', ''
    return raw[:sep + 4], raw[sep + 4:]


def get_header_value(raw: str, name: str):
    header_block, _ = header_body_split(raw)
    for line in split_header_lines(header_block):
        k, _, v = line.partition(':')
        if k.strip().lower() == name.lower():
            return v.strip()
    return None


def rfc2047_decode(s: str) -> str:
    try:
        parts = decode_header(s)
    except Exception:
        return s
    out = []
    for part, enc in parts:
        if isinstance(part, bytes):
            try:
                out.append(part.decode(enc or 'utf-8', errors='replace'))
            except (LookupError, TypeError):
                out.append(part.decode('utf-8', errors='replace'))
        else:
            out.append(part)
    return ''.join(out)


def msg_date(m):
    date_part = m['internaldate'].split(' ')[0]
    return datetime.strptime(date_part, '%d-%b-%Y').date()


def parse_imap_date(s: str):
    return datetime.strptime(s.strip(), '%d-%b-%Y').date()


def parse_search_key(args, i, uids_sorted):
    """Parses one search key at args[i]; returns (predicate, next_index)."""
    t = args[i]
    if isinstance(t, list):
        preds = []
        j = 0
        while j < len(t):
            p, j = parse_search_key(t, j, uids_sorted)
            preds.append(p)
        return (lambda m, ps=preds: all(p(m) for p in ps)), i + 1

    word = t.decode('ascii', 'replace').upper() if isinstance(t, bytes) else ''
    if word == 'ALL':
        return (lambda m: True), i + 1
    if word == 'UID':
        wanted = set(parse_uid_set(astring_val(args[i + 1]), uids_sorted))
        return (lambda m, w=wanted: m['uid'] in w), i + 2
    if word == 'SEEN':
        return (lambda m: '\\Seen' in m['flags']), i + 1
    if word == 'UNSEEN':
        return (lambda m: '\\Seen' not in m['flags']), i + 1
    if word == 'FLAGGED':
        return (lambda m: '\\Flagged' in m['flags']), i + 1
    if word == 'UNFLAGGED':
        return (lambda m: '\\Flagged' not in m['flags']), i + 1
    if word == 'DELETED':
        return (lambda m: '\\Deleted' in m['flags']), i + 1
    if word in ('FROM', 'TO', 'CC', 'SUBJECT'):
        needle = to_unicode(astring_val(args[i + 1])).lower()

        def pred(m, hn=word, nd=needle):
            val = get_header_value(m['raw'], hn)
            if val is None:
                return False
            if nd in to_unicode(val).lower():
                return True
            return nd in rfc2047_decode(val).lower()
        return pred, i + 2
    if word in ('BODY', 'TEXT'):
        needle = to_unicode(astring_val(args[i + 1])).lower()

        def pred(m, nd=needle, w=word):
            if w == 'TEXT':
                return nd in to_unicode(m['raw']).lower()
            _, body = header_body_split(m['raw'])
            return nd in to_unicode(body).lower()
        return pred, i + 2
    if word in ('SINCE', 'BEFORE', 'ON'):
        d = parse_imap_date(astring_val(args[i + 1]))

        def pred(m, w=word, d=d):
            md = msg_date(m)
            if w == 'SINCE':
                return md >= d
            if w == 'BEFORE':
                return md < d
            return md == d
        return pred, i + 2
    if word == 'NOT':
        p, ni = parse_search_key(args, i + 1, uids_sorted)
        return (lambda m, p=p: not p(m)), ni
    if word == 'CHARSET':
        # a stray CHARSET not at the very front; skip it and its value
        return (lambda m: True), i + 2
    # unrecognized key: match everything rather than fail the whole search
    return (lambda m: True), i + 1


SECTION_RE = re.compile(rb'^(BODY\.PEEK|BODY)\[([^\]]*)\](?:<(\d+)(?:\.(\d+))?>)?$', re.IGNORECASE)
FIELDS_RE = re.compile(r'^HEADER\.FIELDS\s*\((.*)\)$', re.IGNORECASE | re.DOTALL)


def normalize_fetch_items(raw_items):
    """Recombines the tokenizer's split of e.g.
    BODY.PEEK[HEADER.FIELDS (FROM TO)] into one ('SECTION', spec) entry;
    other FETCH item atoms become ('ATOM', token)."""
    out = []
    i, n = 0, len(raw_items)
    while i < n:
        t = raw_items[i]
        if isinstance(t, bytes):
            up = t.upper()
            if up.endswith(b'HEADER.FIELDS') and (up.startswith(b'BODY[') or up.startswith(b'BODY.PEEK[')):
                fields_list = raw_items[i + 1] if i + 1 < n and isinstance(raw_items[i + 1], list) else []
                closer = raw_items[i + 2] if i + 2 < n and isinstance(raw_items[i + 2], bytes) else b']'
                fields_text = ' '.join(x.decode('latin-1') for x in fields_list if isinstance(x, bytes))
                combined = (t.decode('latin-1') + '(' + fields_text + ')' + closer.decode('latin-1')).encode('latin-1')
                out.append(('SECTION', combined))
                i += 3
            elif b'BODY' in up and b'[' in up:
                out.append(('SECTION', t))
                i += 1
            else:
                out.append(('ATOM', t))
                i += 1
        else:
            i += 1  # a stray top-level list; not a valid FETCH item, skip it
    return out


def render_section(spec: bytes, m: dict):
    """Returns (response_item_name, content, sets_seen) for one BODY[...]
    or BODY.PEEK[...] fetch item."""
    mm = SECTION_RE.match(spec)
    if not mm:
        return spec.decode('latin-1'), '', False
    peek = mm.group(1).upper() == b'BODY.PEEK'
    inside = mm.group(2).decode('latin-1')
    start = mm.group(3)
    count = mm.group(4)
    header_block, body_block = header_body_split(m['raw'])
    inside_upper = inside.upper()
    if inside == '':
        content = m['raw']
    elif inside_upper == 'HEADER':
        content = header_block
    elif inside_upper == 'TEXT':
        content = body_block
    elif inside_upper.startswith('HEADER.FIELDS'):
        fm = FIELDS_RE.match(inside)
        names = [x.strip().lower() for x in fm.group(1).split()] if fm else []
        lines = split_header_lines(header_block)
        kept = [ln for ln in lines if ln.split(':', 1)[0].strip().lower() in names]
        content = ''.join(ln + '\r\n' for ln in kept) + '\r\n'
    else:
        content = ''
    if start is not None:
        s = int(start)
        content = content[s:s + int(count)] if count is not None else content[s:]
        name = f'BODY[{inside}]<{s}>'
    else:
        name = f'BODY[{inside}]'
    return name, content, not peek


def parse_store_action(tok: bytes):
    s = tok.decode('ascii', 'replace').upper()
    silent = s.endswith('.SILENT')
    if silent:
        s = s[:-len('.SILENT')]
    if s == '+FLAGS':
        return 'add', silent
    if s == '-FLAGS':
        return 'remove', silent
    if s == 'FLAGS':
        return 'replace', silent
    return None, silent


# --------------------------------------------------------------------------
# IMAP session
# --------------------------------------------------------------------------


class IMAPSession:
    FLAGS_LINE = '* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n'

    def __init__(self, sock, state: State, logger: Logger, caps: set):
        self.conn = Conn(sock)
        self.state = state
        self.logger = logger
        self.caps = caps
        self.authenticated = False
        self.mailbox = None
        self.readonly = False
        self.done = False

    def send(self, text: str):
        self.conn.write(text.encode('latin-1'))

    def run(self):
        self.send('* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] fake ready\r\n')
        while not self.done:
            try:
                result = self.read_command()
            except CommandAborted:
                continue
            if result is None:
                return
            tokens, log_line = result
            self.logger.log('imap', log_line)
            self.dispatch(tokens)

    # -- reading one full command, including any literals -----------------

    def decode_mailbox_token(self, tok) -> str:
        return mutf7_decode(astring_val(tok))

    def check_literal(self, cur_tokens, n):
        """Runs before requesting a literal's bytes; lets APPEND answer a
        bad destination with a tagged NO instead of "+", so the client never
        sends bytes the server won't read."""
        if len(cur_tokens) >= 2 and isinstance(cur_tokens[1], bytes) and cur_tokens[1].upper() == b'APPEND':
            if len(cur_tokens) < 3:
                return True, None
            mbox = self.decode_mailbox_token(cur_tokens[2])
            with self.state.lock:
                exists = mbox in self.state.data['mailboxes']
            if not exists:
                tag = astring_val(cur_tokens[0])
                return False, f'{tag} NO [TRYCREATE] mailbox does not exist\r\n'
        return True, None

    def finish_log(self, tokens, log_parts, first_line_text):
        verb = tokens[1].upper() if len(tokens) > 1 and isinstance(tokens[1], bytes) else b''
        if verb == b'LOGIN':
            tag = tokens[0].decode('latin-1') if isinstance(tokens[0], bytes) else '?'
            return f'{tag} LOGIN <redacted>'
        if verb == b'APPEND':
            return first_line_text if first_line_text is not None else ''.join(log_parts)
        return ''.join(log_parts)

    def read_command(self):
        tok = Tokenizer()
        log_parts = []
        first_line_text = None
        while True:
            raw = self.conn.readline()
            if raw is None:
                if log_parts:
                    raise ProtocolError('client closed mid-command')
                return None
            m = LIT_RE.search(raw)
            if m:
                n = int(m.group(1))
                text_before = raw[:m.start()]
                tok.feed_text(text_before)
                seg_text = text_before.decode('latin-1') + '{%d}' % n
                if first_line_text is None:
                    first_line_text = seg_text
                log_parts.append(seg_text)
                cur_tokens = list(tok.stack[0])
                ok, reason = self.check_literal(cur_tokens, n)
                if not ok:
                    self.logger.log('imap', self.finish_log(cur_tokens, log_parts, first_line_text))
                    self.send(reason)
                    raise CommandAborted()
                self.send('+ go ahead\r\n')
                literal = self.conn.readexact(n)
                tok.feed_literal(literal)
                log_parts.append(literal.decode('latin-1'))
                continue
            tok.feed_text(raw)
            text = raw[:-2] if raw.endswith(b'\r\n') else raw.rstrip(b'\n')
            seg_text = text.decode('latin-1')
            if first_line_text is None:
                first_line_text = seg_text
            log_parts.append(seg_text)
            break
        tokens = tok.stack[0]
        return tokens, self.finish_log(tokens, log_parts, first_line_text)

    # -- dispatch -----------------------------------------------------------

    def require_selected(self, tag):
        if self.mailbox is None:
            self.send(f'{tag} BAD no mailbox selected\r\n')
            return None
        return self.mailbox

    def dispatch(self, tokens):
        if not tokens or not isinstance(tokens[0], bytes):
            return
        tag = tokens[0].decode('latin-1')
        if len(tokens) < 2 or not isinstance(tokens[1], bytes):
            self.send(f'{tag} BAD missing command\r\n')
            return
        verb = tokens[1].upper()
        args = tokens[2:]
        uid_mode = False
        if verb == b'UID':
            if not args or not isinstance(args[0], bytes):
                self.send(f'{tag} BAD malformed UID command\r\n')
                return
            uid_mode = True
            verb = args[0].upper()
            args = args[1:]

        if not self.authenticated and verb not in (b'CAPABILITY', b'NOOP', b'LOGOUT', b'LOGIN'):
            self.send(f'{tag} NO authentication required\r\n')
            return

        if verb == b'CAPABILITY':
            self.cmd_capability(tag)
        elif verb == b'LOGIN':
            self.cmd_login(tag, args)
        elif verb == b'LOGOUT':
            self.cmd_logout(tag)
        elif verb == b'NOOP':
            self.send(f'{tag} OK NOOP completed\r\n')
        elif verb == b'LIST':
            self.cmd_list(tag, args)
        elif verb in (b'SELECT', b'EXAMINE'):
            self.cmd_select(tag, args, readonly=(verb == b'EXAMINE'))
        elif uid_mode and verb == b'SEARCH':
            self.cmd_search(tag, args)
        elif uid_mode and verb == b'FETCH':
            self.cmd_fetch(tag, args)
        elif uid_mode and verb == b'STORE':
            self.cmd_store(tag, args)
        elif uid_mode and verb == b'COPY':
            self.cmd_copy(tag, args)
        elif uid_mode and verb == b'MOVE':
            self.cmd_move(tag, args)
        elif uid_mode and verb == b'EXPUNGE':
            self.cmd_uid_expunge(tag, args)
        elif verb == b'EXPUNGE' and not uid_mode:
            self.cmd_expunge(tag)
        elif verb == b'APPEND':
            self.cmd_append(tag, args)
        else:
            self.send(f'{tag} BAD unknown command\r\n')

    # -- commands -----------------------------------------------------------

    def cmd_capability(self, tag):
        if self.authenticated:
            extra = ' '.join(sorted(self.caps))
            self.send(f'* CAPABILITY IMAP4rev1{(" " + extra) if extra else ""}\r\n')
        else:
            self.send('* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\n')
        self.send(f'{tag} OK CAPABILITY completed\r\n')

    def cmd_login(self, tag, args):
        if len(args) < 2:
            self.send(f'{tag} BAD malformed LOGIN\r\n')
            return
        user, pw = astring_val(args[0]), astring_val(args[1])
        with self.state.lock:
            ok = user == self.state.data['user'] and pw == self.state.data['password']
        if ok:
            self.authenticated = True
            echo = f' as {user} with {pw}' if self.state.echo_login else ''
            self.send(f'{tag} OK LOGIN completed{echo}\r\n')
        else:
            self.send(f'{tag} NO [AUTHENTICATIONFAILED] invalid credentials\r\n')

    def cmd_logout(self, tag):
        self.send('* BYE fake logging out\r\n')
        self.send(f'{tag} OK LOGOUT completed\r\n')
        self.done = True

    def cmd_list(self, tag, args):
        with self.state.lock:
            names = list(self.state.data['mailboxes'].keys())
            specials = {n: list(self.state.data['mailboxes'][n]['special']) for n in names}
        asked = any(astring_val(a).upper() == 'RETURN' for a in args)
        if asked and self.state.special_return_fails:
            self.send(f'{tag} NO [UNAVAILABLE] special-use lookup failed\r\n')
            return
        # --special-on-request: special-use attributes only for LIST ... RETURN (SPECIAL-USE)
        show = 'SPECIAL-USE' in self.caps and (asked or not self.state.special_on_request)
        for name in names:
            has_children = any(other != name and other.startswith(name + '/') for other in names)
            attrs = ['\\HasChildren' if has_children else '\\HasNoChildren']
            if show:
                attrs.extend(specials[name])
            self.send(f'* LIST ({" ".join(attrs)}) "/" {imap_quote(mutf7_encode(name))}\r\n')
        self.send(f'{tag} OK LIST completed\r\n')

    def cmd_select(self, tag, args, readonly):
        if not args:
            self.send(f'{tag} BAD missing mailbox\r\n')
            return
        name = self.decode_mailbox_token(args[0])
        with self.state.lock:
            mb = self.state.data['mailboxes'].get(name)
            if mb is None:
                self.mailbox = None
                self.send(f'{tag} NO [NONEXISTENT] no such mailbox\r\n')
                return
            count, uidvalidity, uidnext = len(mb['messages']), mb['uidvalidity'], mb['uidnext']
        self.mailbox, self.readonly = name, readonly
        self.send(self.FLAGS_LINE)
        self.send(f'* {count} EXISTS\r\n')
        self.send('* 0 RECENT\r\n')
        ok = '* ok [uidvalidity' if self.state.lowercase_codes else '* OK [UIDVALIDITY'
        self.send(f'{ok} {uidvalidity}] UIDs valid\r\n')
        self.send(f'* OK [UIDNEXT {uidnext}] Predicted next UID\r\n')
        mode, verb_name = ('READ-ONLY', 'EXAMINE') if readonly else ('READ-WRITE', 'SELECT')
        self.send(f'{tag} OK [{mode}] {verb_name} completed\r\n')

    def cmd_search(self, tag, args):
        mbox = self.require_selected(tag)
        if mbox is None:
            return
        i = 0
        if len(args) >= 2 and isinstance(args[0], bytes) and args[0].upper() == b'CHARSET':
            i = 2
        with self.state.lock:
            messages = self.state.data['mailboxes'][mbox]['messages']
            uids_sorted = sorted(m['uid'] for m in messages)
            preds = []
            j = i
            while j < len(args):
                p, j = parse_search_key(args, j, uids_sorted)
                preds.append(p)
            matched = sorted(m['uid'] for m in messages if all(p(m) for p in preds))
        self.send('* SEARCH' + (' ' + ' '.join(str(u) for u in matched) if matched else '') + '\r\n')
        self.send(f'{tag} OK SEARCH completed\r\n')

    def build_fetch_response(self, seq, m, items):
        parts = []
        have_uid = False
        seen_added = False
        for kind, spec in items:
            if kind == 'ATOM':
                word = spec.decode('ascii', 'replace').upper() if isinstance(spec, bytes) else ''
                if word == 'UID':
                    parts.append(f'UID {m["uid"]}')
                    have_uid = True
                elif word == 'FLAGS':
                    parts.append('FLAGS (' + ' '.join(m['flags']) + ')')
                elif word == 'INTERNALDATE':
                    parts.append(f'INTERNALDATE "{m["internaldate"]}"')
                elif word == 'RFC822.SIZE':
                    parts.append(f'RFC822.SIZE {len(m["raw"])}')
            else:
                name, content, sets_seen = render_section(spec, m)
                if sets_seen and not self.readonly and '\\Seen' not in m['flags']:
                    m['flags'].append('\\Seen')
                    seen_added = True
                parts.append(f'{name} {{{len(content)}}}\r\n{content}')
        if not have_uid:
            parts.insert(0, f'UID {m["uid"]}')
        return f'* {seq} FETCH (' + ' '.join(parts) + ')\r\n', seen_added

    def cmd_fetch(self, tag, args):
        mbox = self.require_selected(tag)
        if mbox is None:
            return
        if len(args) < 2:
            self.send(f'{tag} BAD malformed FETCH\r\n')
            return
        spec = astring_val(args[0])
        items_raw = args[1] if isinstance(args[1], list) else [args[1]]
        items = normalize_fetch_items(items_raw)
        out_lines = []
        with self.state.lock:
            messages = self.state.data['mailboxes'][mbox]['messages']
            messages.sort(key=lambda m: m['uid'])
            wanted = set(parse_uid_set(spec, [m['uid'] for m in messages]))
            mutated = False
            for seq, m in enumerate(messages, start=1):
                if m['uid'] not in wanted:
                    continue
                line, seen_added = self.build_fetch_response(seq, m, items)
                mutated = mutated or seen_added
                out_lines.append(line)
            if mutated:
                self.state.save()
        for line in out_lines:
            self.send(line)
        self.send(f'{tag} OK FETCH completed\r\n')

    def cmd_store(self, tag, args):
        mbox = self.require_selected(tag)
        if mbox is None:
            return
        if self.readonly:
            self.send(f'{tag} NO mailbox is read-only\r\n')
            return
        if len(args) < 3 or not isinstance(args[1], bytes):
            self.send(f'{tag} BAD malformed STORE\r\n')
            return
        spec = astring_val(args[0])
        action, silent = parse_store_action(args[1])
        if action is None:
            self.send(f'{tag} BAD malformed STORE\r\n')
            return
        flags_list = args[2] if isinstance(args[2], list) else [args[2]]
        flag_names = [f.decode('ascii', 'replace') for f in flags_list if isinstance(f, bytes)]
        out_lines = []
        with self.state.lock:
            messages = self.state.data['mailboxes'][mbox]['messages']
            messages.sort(key=lambda m: m['uid'])
            wanted = set(parse_uid_set(spec, [m['uid'] for m in messages]))
            for seq, m in enumerate(messages, start=1):
                if m['uid'] not in wanted:
                    continue
                if action == 'add':
                    for fl in flag_names:
                        if fl not in m['flags']:
                            m['flags'].append(fl)
                elif action == 'remove':
                    m['flags'] = [f for f in m['flags'] if f not in flag_names]
                else:
                    m['flags'] = list(flag_names)
                if not silent:
                    out_lines.append(f'* {seq} FETCH (UID {m["uid"]} FLAGS (' + ' '.join(m['flags']) + '))\r\n')
            self.state.save()
        for line in out_lines:
            self.send(line)
        self.send(f'{tag} OK STORE completed\r\n')

    def cmd_copy(self, tag, args):
        mbox = self.require_selected(tag)
        if mbox is None:
            return
        if len(args) < 2:
            self.send(f'{tag} BAD malformed COPY\r\n')
            return
        spec = astring_val(args[0])
        dest = self.decode_mailbox_token(args[1])
        with self.state.lock:
            mailboxes = self.state.data['mailboxes']
            if dest not in mailboxes:
                self.send(f'{tag} NO [TRYCREATE] destination does not exist\r\n')
                return
            src_msgs = mailboxes[mbox]['messages']
            src_msgs.sort(key=lambda m: m['uid'])
            wanted = set(parse_uid_set(spec, [m['uid'] for m in src_msgs]))
            dst = mailboxes[dest]
            src_uids, dst_uids = [], []
            for m in src_msgs:
                if m['uid'] not in wanted:
                    continue
                new_uid = dst['uidnext']
                dst['uidnext'] += 1
                dst['messages'].append({'uid': new_uid, 'flags': list(m['flags']),
                                         'internaldate': m['internaldate'], 'raw': m['raw']})
                src_uids.append(m['uid'])
                dst_uids.append(new_uid)
            dst_validity = dst['uidvalidity']
            self.state.save()
        if 'UIDPLUS' in self.caps and src_uids:
            srcset, dstset = ','.join(map(str, src_uids)), ','.join(map(str, dst_uids))
            self.send(f'{tag} OK [COPYUID {dst_validity} {srcset} {dstset}] COPY completed\r\n')
        else:
            self.send(f'{tag} OK COPY completed\r\n')

    def cmd_move(self, tag, args):
        mbox = self.require_selected(tag)
        if mbox is None:
            return
        if 'MOVE' not in self.caps:
            self.send(f'{tag} BAD MOVE not supported\r\n')
            return
        if len(args) < 2:
            self.send(f'{tag} BAD malformed MOVE\r\n')
            return
        spec = astring_val(args[0])
        dest = self.decode_mailbox_token(args[1])
        with self.state.lock:
            mailboxes = self.state.data['mailboxes']
            if dest not in mailboxes:
                self.send(f'{tag} NO [TRYCREATE] destination does not exist\r\n')
                return
            src_msgs = mailboxes[mbox]['messages']
            src_msgs.sort(key=lambda m: m['uid'])
            wanted = set(parse_uid_set(spec, [m['uid'] for m in src_msgs]))
            dst = mailboxes[dest]
            src_uids, dst_uids, remaining, expunge_seqs = [], [], [], []
            for seq, m in enumerate(src_msgs, start=1):
                if m['uid'] in wanted:
                    new_uid = dst['uidnext']
                    dst['uidnext'] += 1
                    dst['messages'].append({'uid': new_uid, 'flags': list(m['flags']),
                                             'internaldate': m['internaldate'], 'raw': m['raw']})
                    src_uids.append(m['uid'])
                    dst_uids.append(new_uid)
                    expunge_seqs.append(seq)
                else:
                    remaining.append(m)
            mailboxes[mbox]['messages'] = remaining
            dst_validity = dst['uidvalidity']
            self.state.save()
        if src_uids:
            srcset, dstset = ','.join(map(str, src_uids)), ','.join(map(str, dst_uids))
            self.send(f'* OK [COPYUID {dst_validity} {srcset} {dstset}] MOVE completed\r\n')
            for seq in sorted(expunge_seqs, reverse=True):
                self.send(f'* {seq} EXPUNGE\r\n')
        self.send(f'{tag} OK MOVE completed\r\n')

    def _expunge(self, tag, mbox, spec):
        with self.state.lock:
            messages = self.state.data['mailboxes'][mbox]['messages']
            messages.sort(key=lambda m: m['uid'])
            uids_sorted = [m['uid'] for m in messages]
            wanted = set(parse_uid_set(spec, uids_sorted)) if spec is not None else set(uids_sorted)
            remaining, expunge_seqs = [], []
            for seq, m in enumerate(messages, start=1):
                if m['uid'] in wanted and '\\Deleted' in m['flags']:
                    expunge_seqs.append(seq)
                else:
                    remaining.append(m)
            self.state.data['mailboxes'][mbox]['messages'] = remaining
            self.state.save()
        for seq in sorted(expunge_seqs, reverse=True):
            self.send(f'* {seq} EXPUNGE\r\n')
        self.send(f'{tag} OK EXPUNGE completed\r\n')

    def cmd_uid_expunge(self, tag, args):
        mbox = self.require_selected(tag)
        if mbox is None:
            return
        if 'UIDPLUS' not in self.caps:
            self.send(f'{tag} BAD UIDPLUS not supported\r\n')
            return
        if not args:
            self.send(f'{tag} BAD malformed EXPUNGE\r\n')
            return
        self._expunge(tag, mbox, astring_val(args[0]))

    def cmd_expunge(self, tag):
        mbox = self.require_selected(tag)
        if mbox is None:
            return
        self._expunge(tag, mbox, None)

    def cmd_append(self, tag, args):
        if not args:
            self.send(f'{tag} BAD malformed APPEND\r\n')
            return
        dest = self.decode_mailbox_token(args[0])
        idx = 1
        flags = []
        if idx < len(args) and isinstance(args[idx], list):
            flags = [f.decode('ascii', 'replace') for f in args[idx] if isinstance(f, bytes)]
            idx += 1
        date_str = None
        if idx < len(args) - 1 and isinstance(args[idx], bytes):
            date_str = astring_val(args[idx])
            idx += 1
        if idx >= len(args) or not isinstance(args[idx], bytes):
            self.send(f'{tag} BAD malformed APPEND\r\n')
            return
        content = astring_val(args[idx])
        with self.state.lock:
            mb = self.state.data['mailboxes'].get(dest)
            if mb is None:
                self.send(f'{tag} NO [TRYCREATE] mailbox does not exist\r\n')
                return
            new_uid = mb['uidnext']
            mb['uidnext'] += 1
            internaldate = date_str or datetime.now(timezone.utc).strftime('%d-%b-%Y %H:%M:%S +0000')
            mb['messages'].append({'uid': new_uid, 'flags': flags, 'internaldate': internaldate, 'raw': content})
            validity = mb['uidvalidity']
            self.state.save()
        if 'UIDPLUS' in self.caps:
            self.send(f'{tag} OK [APPENDUID {validity} {new_uid}] APPEND completed\r\n')
        else:
            self.send(f'{tag} OK APPEND completed\r\n')


# --------------------------------------------------------------------------
# SMTP session
# --------------------------------------------------------------------------


class SMTPSession:
    def __init__(self, sock, state: State, logger: Logger, ssl_ctx, starttls_offered: bool):
        self.conn = Conn(sock)
        self.state = state
        self.logger = logger
        self.ssl_ctx = ssl_ctx
        self.starttls_offered = starttls_offered
        self.tls_active = False
        self.authenticated = False
        self.mail_from = None
        self.rcpt_to = []
        self.auth_login_stage = 0  # 0 none, 1 awaiting username, 2 awaiting password
        self._pending_user = None

    def send(self, text: str):
        self.conn.write(text.encode('latin-1'))

    def _decode_line(self, raw: bytes) -> str:
        if raw.endswith(b'\r\n'):
            raw = raw[:-2]
        elif raw.endswith(b'\n'):
            raw = raw[:-1]
        return raw.decode('latin-1')

    def _b64decode_safe(self, text: str) -> str:
        try:
            return base64.b64decode(text.strip()).decode('utf-8', 'replace')
        except Exception:
            return ''

    def _echo(self) -> str:
        if not self.state.echo_login:
            return ''
        return ' as ' + self.state.data['user'] + ' with ' + self.state.data['password']

    def _check_creds(self, user: str, pw: str) -> bool:
        with self.state.lock:
            return user == self.state.data['user'] and pw == self.state.data['password']

    def run(self):
        self.send('220 fake ESMTP\r\n')
        while True:
            raw = self.conn.readline()
            if raw is None:
                return
            text = self._decode_line(raw)
            if self.auth_login_stage in (1, 2) or text.upper().startswith('AUTH '):
                self.logger.log('smtp', 'AUTH <redacted>')
            else:
                self.logger.log('smtp', text)
            if not self.handle_line(text):
                return
            if getattr(self, 'closing', False):
                self.conn.sock.shutdown(socket.SHUT_RDWR)
                self.conn.sock.close()
                return

    def handle_line(self, text: str) -> bool:
        if self.auth_login_stage == 1:
            self._pending_user = self._b64decode_safe(text)
            self.send('334 ' + base64.b64encode(b'Password:').decode('ascii') + '\r\n')
            self.auth_login_stage = 2
            return True
        if self.auth_login_stage == 2:
            pw = self._b64decode_safe(text)
            self.auth_login_stage = 0
            if self._check_creds(self._pending_user or '', pw):
                self.authenticated = True
                self.send('235 2.7.0 Authentication successful' + self._echo() + '\r\n')
            else:
                self.send('535 5.7.8 Authentication failed\r\n')
            return True

        verb, _, rest = text.partition(' ')
        verb_up = verb.upper()
        if verb_up in ('EHLO', 'HELO'):
            self.cmd_ehlo()
        elif verb_up == 'STARTTLS':
            self.cmd_starttls()
        elif verb_up == 'AUTH':
            self.cmd_auth(rest)
        elif verb_up == 'MAIL':
            self.cmd_mail(text)
        elif verb_up == 'RCPT':
            self.cmd_rcpt(text)
        elif verb_up == 'DATA':
            self.cmd_data()
        elif verb_up == 'RSET':
            self.mail_from, self.rcpt_to = None, []
            self.send('250 2.0.0 OK\r\n')
        elif verb_up == 'NOOP':
            self.send('250 2.0.0 OK\r\n')
        elif verb_up == 'QUIT':
            self.send('221 2.0.0 Bye\r\n')
            return False
        else:
            self.send('500 5.5.1 unrecognized command\r\n')
        return True

    def cmd_ehlo(self):
        lines = ['fake greets you']
        if self.starttls_offered and not self.tls_active:
            lines.append('STARTTLS')
        if self.tls_active:
            lines.append('AUTH PLAIN LOGIN')
        for line in lines[:-1]:
            self.send(f'250-{line}\r\n')
        self.send(f'250 {lines[-1]}\r\n')

    def cmd_starttls(self):
        if not self.starttls_offered or self.tls_active:
            self.send('454 4.7.0 TLS not available\r\n')
            return
        self.send('220 go ahead\r\n')
        try:
            wrapped = self.ssl_ctx.wrap_socket(self.conn.sock, server_side=True)
        except (ssl.SSLError, OSError):
            raise ConnectionClosed()
        self.conn = Conn(wrapped)
        self.tls_active = True

    def cmd_auth(self, rest: str):
        if not self.tls_active:
            self.send('530 5.7.0 STARTTLS required\r\n')
            return
        parts = rest.strip().split(' ', 1)
        mech = parts[0].upper() if parts and parts[0] else ''
        if mech == 'PLAIN':
            if len(parts) < 2:
                self.send('535 5.7.8 Authentication failed\r\n')
                return
            try:
                raw = base64.b64decode(parts[1])
                _, user, pw = raw.split(b'\0', 2)
            except Exception:
                self.send('535 5.7.8 Authentication failed\r\n')
                return
            if self._check_creds(user.decode('utf-8', 'replace'), pw.decode('utf-8', 'replace')):
                self.authenticated = True
                self.send('235 2.7.0 Authentication successful' + self._echo() + '\r\n')
            else:
                self.send('535 5.7.8 Authentication failed\r\n')
        elif mech == 'LOGIN':
            self.send('334 ' + base64.b64encode(b'Username:').decode('ascii') + '\r\n')
            self.auth_login_stage = 1
        else:
            self.send('504 5.5.4 unrecognized authentication mechanism\r\n')

    def cmd_mail(self, text: str):
        if not self.authenticated:
            self.send('530 5.7.0 Authentication required\r\n')
            return
        m = re.match(r'(?i)^MAIL\s+FROM:\s*<([^>]*)>', text)
        if not m:
            self.send('501 5.5.4 malformed MAIL command\r\n')
            return
        self.mail_from, self.rcpt_to = m.group(1), []
        self.send('250 2.1.0 OK\r\n')

    def cmd_rcpt(self, text: str):
        if not self.authenticated:
            self.send('530 5.7.0 Authentication required\r\n')
            return
        if self.mail_from is None:
            self.send('503 5.5.1 MAIL first\r\n')
            return
        m = re.match(r'(?i)^RCPT\s+TO:\s*<([^>]*)>', text)
        if not m:
            self.send('501 5.5.4 malformed RCPT command\r\n')
            return
        addr = m.group(1)
        if addr.lower() == 'reject@example.com':
            self.send('550 5.1.1 mailbox unavailable\r\n')
            return
        if addr.lower() == 'closing@example.com':
            # a closing rejection: the server hangs up right after replying
            self.send('421 4.3.2 service shutting down\r\n')
            self.closing = True
            return
        self.rcpt_to.append(addr)
        self.send('250 2.1.5 OK\r\n')

    def cmd_data(self):
        if not self.authenticated:
            self.send('530 5.7.0 Authentication required\r\n')
            return
        if self.mail_from is None or not self.rcpt_to:
            self.send('503 5.5.1 need MAIL and RCPT first\r\n')
            return
        self.send('354 Start mail input; end with <CRLF>.<CRLF>\r\n')
        lines = []
        while True:
            raw = self.conn.readline()
            if raw is None:
                raise ConnectionClosed()
            text = self._decode_line(raw)
            if text == '.':
                break
            if text.startswith('.'):
                text = text[1:]
            lines.append(text)
        data = ('\r\n'.join(lines) + '\r\n') if lines else ''
        self.logger.log('smtp', f'<message {len(data)} bytes>')
        with self.state.lock:
            self.state.data['sent'].append({'mail_from': self.mail_from, 'rcpt_to': list(self.rcpt_to), 'data': data})
            n = len(self.state.data['sent'])
            self.state.save()
        self.mail_from, self.rcpt_to = None, []
        self.send(f'250 2.0.0 OK queued as FAKE{n}\r\n')


# --------------------------------------------------------------------------
# Server bootstrap
# --------------------------------------------------------------------------


def make_ssl_context(certdir: str, cert_name: str) -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(certdir, f'{cert_name}.pem'), os.path.join(certdir, f'{cert_name}-key.pem'))
    return ctx


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--certdir', required=True)
    ap.add_argument('--fixture', required=True)
    ap.add_argument('--state', required=True)
    ap.add_argument('--log', required=True)
    ap.add_argument('--caps', default='MOVE,UIDPLUS,SPECIAL-USE,IDLE')
    ap.add_argument('--no-starttls', action='store_true')
    ap.add_argument('--cert-name', default='server')
    ap.add_argument('--silent-port', action='store_true')
    ap.add_argument('--echo-login', action='store_true', help='echo the credentials in login replies')
    ap.add_argument('--lowercase-codes', action='store_true', help='send response codes in lower case')
    ap.add_argument('--special-on-request', action='store_true',
                    help='mark special-use folders only for LIST ... RETURN (SPECIAL-USE)')
    ap.add_argument('--special-return-fails', action='store_true',
                    help='answer NO to LIST ... RETURN (SPECIAL-USE)')
    args = ap.parse_args()

    with open(args.fixture, encoding='utf-8') as f:
        fixture = json.load(f)
    state = State(fixture, args.state)
    state.echo_login = args.echo_login
    state.lowercase_codes = args.lowercase_codes
    state.special_on_request = args.special_on_request
    state.special_return_fails = args.special_return_fails
    logger = Logger(args.log)
    caps = {x.strip().upper() for x in args.caps.split(',') if x.strip()}
    ctx = make_ssl_context(args.certdir, args.cert_name)

    def make_listener():
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(('127.0.0.1', 0))
        s.listen(16)
        return s

    imap_sock, smtp_sock = make_listener(), make_listener()
    silent_sock = make_listener() if args.silent_port else None

    running = True

    def handle_sigterm(signum, frame):
        nonlocal running
        running = False
        for s in (imap_sock, smtp_sock, silent_sock):
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass

    signal.signal(signal.SIGTERM, handle_sigterm)
    signal.signal(signal.SIGINT, handle_sigterm)

    def accept_loop(sock, handler):
        while running:
            try:
                conn, _ = sock.accept()
            except OSError:
                break
            conn.settimeout(60)
            threading.Thread(target=handler, args=(conn,), daemon=True).start()

    def imap_handler(conn):
        try:
            tls_conn = ctx.wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError):
            conn.close()
            return
        try:
            IMAPSession(tls_conn, state, logger, caps).run()
        except (ConnectionClosed, ProtocolError):
            pass
        finally:
            try:
                tls_conn.close()
            except OSError:
                pass

    def smtp_handler(conn):
        try:
            SMTPSession(conn, state, logger, ctx, not args.no_starttls).run()
        except (ConnectionClosed, ProtocolError):
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    held_silent_conns = []  # never touched, just kept alive until shutdown

    def silent_handler(conn):
        held_silent_conns.append(conn)

    threads = [
        threading.Thread(target=accept_loop, args=(imap_sock, imap_handler), daemon=True),
        threading.Thread(target=accept_loop, args=(smtp_sock, smtp_handler), daemon=True),
    ]
    if silent_sock is not None:
        threads.append(threading.Thread(target=accept_loop, args=(silent_sock, silent_handler), daemon=True))
    for t in threads:
        t.start()

    ready = f'READY imap={imap_sock.getsockname()[1]} smtp={smtp_sock.getsockname()[1]}'
    if silent_sock is not None:
        ready += f' silent={silent_sock.getsockname()[1]}'
    print(ready, flush=True)

    while running:
        time.sleep(0.2)


if __name__ == '__main__':
    main()
