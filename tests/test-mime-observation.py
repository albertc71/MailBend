#!/usr/bin/env python3
"""Source preparation for the #124 experiment. Runtime has no CLI entry point.

The source audit is intentionally implementation-coupled. It is not a public
behavior test and does not establish runtime equivalence or close #124.
"""
import argparse
import base64
import copy
import contextlib
from dataclasses import dataclass
import difflib
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import secrets
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
BASE = '1970639fcfcc7589bc62e95adf8d49341b378136'
BASE_TREE = 'd662d9f9a986cc01a1a16ef0326cdc556a84e68f'
TOOLS_SHA256 = 'f3bfd60ad472e1a94912890ca648058f2b6b8aaa08ebb70f7be93adb3b987070'
NEW_FILES = ('tests/test-mime-observation.py', 'tests/mime-observation.bend')
MAX_WIRE = 1572864
MAX_CAPTURE = 4194304
MAX_TEST_SOURCE = 131072
SCENARIO = 'cli-stdin-one-mib-draft'
INITIAL_STATE_SHA256 = 'd4d3ac62b6988b599a95a0f0c4eb8a03dff1c66ea98be53f2361e1773f71f509'
RUNTIME_ARTIFACTS = {'stock_core', 'observed_core', 'mime_oracle', 'tls_helper', 'attach_helper',
                     'python', 'openssl', 'shell', 'date', 'dirname', 'git'}
BUILD_IDENTITIES = {'bend', 'bend_base', 'clang', 'rustc', 'cargo', 'provenance'}
CA_WARNING = (b'mailbend: warning: MAILBEND_CA_FILE replaces the system trust store; '
              b'it is meant for local tests\n')
EXPECTED_SITES = ('draft',)
IMPORT = 'import ./mime.bend as M\n'
OBSERVER_IMPORT = 'import ../tests/mime-observation.bend as MimeObservation\n'
OLD_DRAFT = '''        r : Run() <- imap_run(Ops.plan_probe())
        draft_folder(r, M.compose(d, boundary_of(st)), msgid_of(d), is_dry(w))'''
NEW_DRAFT = '''        r : Run() <- imap_run(Ops.plan_probe())
        msg : String <- MimeObservation.observe(M.compose(d, boundary_of(st)))
        draft_folder(r, msg, msgid_of(d), is_dry(w))'''
SITES = (
    '        c : String <- sent_copy(msgid, M.compose(copy, boundary))',
    '      +msg = M.compose(d, boundary_of(st))',
    '        draft_folder(r, M.compose(d, boundary_of(st)), msgid_of(d), is_dry(w))',
)
MIME_IMPORTERS = {
    'src/' + name + '.bend': ['M'] for name in (
        'awaiting', 'brief', 'contacts', 'hook', 'jev', 'message-metadata',
        'providers', 'response', 'secrets', 'sections', 'thread', 'tools')
}


class Refused(Exception):
    pass


def require(ok, category):
    if not ok:
        raise Refused(category)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def transform(source):
    require(sha(source.encode()) == TOOLS_SHA256, 'source hash')
    for fragment in (IMPORT, OLD_DRAFT, *SITES):
        require(source.count(fragment) == 1, 'source fragment')
    require(source.count('M.compose(') == 3, 'composition inventory')
    return source.replace(IMPORT, IMPORT + OBSERVER_IMPORT).replace(OLD_DRAFT, NEW_DRAFT)


def inventory(files):
    aliases = {}
    sites = []
    for name, data in sorted(files.items()):
        if not name.endswith('.bend') or not (name.startswith('src/') or name == 'main.bend'):
            continue
        source = data.decode()
        imports = [line for line in source.splitlines()
                   if line.startswith('import ') and 'mime.bend' in line]
        found = []
        for line in imports:
            match = re.fullmatch(r'import \./mime\.bend as (\w+)', line)
            require(match is not None, 'unknown MIME import')
            found.append(match[1])
        if found:
            aliases[name] = found
        for alias in found:
            for line in source.splitlines():
                if re.search(r'\b' + re.escape(alias) + r'\.compose\b', line):
                    sites.append((name, line))
    require(aliases == MIME_IMPORTERS, 'MIME import inventory')
    require(sites == [('src/tools.bend', line) for line in SITES], 'composition inventory')


def git(*args, control=None):
    command = ['/usr/bin/git', '-C', str(ROOT), *args]
    environment = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C',
                   'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'}
    if control is not None:
        result = checked_child(command, environment, ROOT, control, output_limit=MAX_CAPTURE)
        require(result['stderr'] == b'', 'git source diagnostics')
        return result['stdout']
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=30, env=environment)
    require(result.returncode == 0, 'git source read')
    return result.stdout


def read_regular(path, limit):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode), 'source file type')
    require(info.st_size <= limit, 'source file bound')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened = os.fstat(descriptor)
        require(stat.S_ISREG(opened.st_mode), 'source file type')
        require((info.st_dev, info.st_ino) == (opened.st_dev, opened.st_ino), 'source file replaced')
        require(opened.st_size <= limit, 'source file bound')
        with os.fdopen(descriptor, 'rb', closefd=False) as stream:
            data = stream.read(limit + 1)
    finally:
        os.close(descriptor)
    require(len(data) <= limit, 'source file bound')
    return data, opened.st_mode


def baseline(control=None):
    require(git('rev-parse', BASE, control=control).decode().strip() == BASE, 'baseline revision')
    require(git('rev-parse', BASE + '^{tree}', control=control).decode().strip() == BASE_TREE, 'baseline tree')
    files, modes = {}, {}
    for entry in git('ls-tree', '-rz', BASE, control=control).split(b'\0'):
        if not entry:
            continue
        metadata, path = entry.split(b'\t', 1)
        mode, kind, blob = metadata.decode().split()
        name = path.decode()
        require(kind == 'blob' and mode in ('100644', '100755', '120000'), 'tree object')
        require(not name.startswith('/') and '..' not in Path(name).parts, 'tree path')
        files[name] = git('cat-file', 'blob', blob, control=control)
        modes[name] = mode
    inventory(files)
    require(sha(files['src/tools.bend']) == TOOLS_SHA256, 'source hash')
    for name, data in files.items():
        path = ROOT / name
        if modes[name] == '120000':
            require(path.is_symlink() and os.readlink(path).encode() == data, 'working source drift')
        else:
            actual, mode = read_regular(path, len(data))
            require(actual == data, 'working source drift')
            require(bool(mode & 0o111) == (modes[name] == '100755'), 'source mode drift')
    return files, modes


def private_write(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(data)


def check_export(destination, files, modes, tools, module):
    expected = dict(files)
    expected['src/tools.bend'] = tools
    expected['tests/mime-observation.bend'] = module
    paths = {str(p.relative_to(destination)) for p in destination.rglob('*')
             if p.is_symlink() or p.is_file()}
    require(paths == set(expected), 'export paths')
    for name, data in expected.items():
        path = destination / name
        mode = modes.get(name, '100644')
        if mode == '120000':
            require(path.is_symlink() and os.readlink(path).encode() == data, 'export symlink')
        else:
            actual, actual_mode = read_regular(path, len(data))
            require(actual == data, 'export bytes')
            require(stat.S_IMODE(actual_mode) == int(mode[-3:], 8), 'export modes')


def prepare():
    files, modes = baseline()
    candidates = {name: read_regular(ROOT / name, MAX_TEST_SOURCE)[0] for name in NEW_FILES}
    parent = ROOT / 'build'
    parent.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='mime-observation-', dir=parent))
    try:
        os.chmod(work, 0o700)
        destination = work / 'source'
        destination.mkdir(mode=0o700)
        for name, data in files.items():
            path = destination / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if modes[name] == '120000':
                target = (path.parent / data.decode()).resolve()
                require(target.is_relative_to(destination.resolve()), 'export symlink target')
                path.symlink_to(data.decode())
            else:
                private_write(path, data)
                path.chmod(int(modes[name][-3:], 8))
        tools = transform(files['src/tools.bend'].decode()).encode()
        (destination / 'src/tools.bend').write_bytes(tools)
        module = candidates[NEW_FILES[1]].decode()
        substitutions = {
            'False{} # @PREPARED@': 'True{} # private generated experiment',
            '@CONTEXT_PATH@': str(work / 'context'),
            '@CONTEXT_TOKEN@': secrets.token_hex(32),
            '@CAPTURE_PATH@': str(work / 'capture'),
        }
        for marker, value in substitutions.items():
            require(module.count(marker) == 1, 'observer template')
            require('"' not in value and '\n' not in value and '\\' not in value, 'observer literal')
            module = module.replace(marker, value)
        private_write(destination / NEW_FILES[1], module.encode())
        (destination / NEW_FILES[1]).chmod(0o644)
        private_write(work / 'capture', b'')
        # Source preparation never arms the context file or executes the export.
        require(not (work / 'context').exists(), 'unarmed preparation')
        check_export(destination, files, modes, tools, module.encode())
        patch = ''.join(difflib.unified_diff(files['src/tools.bend'].decode().splitlines(True),
                                           tools.decode().splitlines(True),
                                           'stock/src/tools.bend', 'observed/src/tools.bend'))
        private_write(work / 'generated.patch', patch.encode())
        manifest = {'base': BASE, 'tree': BASE_TREE, 'scope': 'draft-only, source-only',
                    'instrumented_sites': list(EXPECTED_SITES),
                    'uninstrumented_sites': ['outbound', 'sent-copy'],
                    'tools_sha256': sha(tools), 'module_sha256': sha(module.encode()),
                    'files': {name: {'mode': modes.get(name, '100644'), 'sha256': sha(data)}
                              for name, data in files.items()},
                    'candidate_files': {name: sha(data) for name, data in candidates.items()}}
        private_write(work / 'manifest.json', (json.dumps(manifest, indent=2) + '\n').encode())
        return work
    except BaseException:
        shutil.rmtree(work)
        raise


@dataclass(frozen=True)
class Observation:
    site: str
    wire: bytes


def read_records(data):
    require(len(data) <= MAX_CAPTURE, 'capture bound')
    records = []
    offset = 0
    while offset < len(data):
        end = data.find(b'\n', offset, offset + 64)
        require(end >= 0, 'record framing')
        header = re.fullmatch(rb'MB124 (draft) ([1-9][0-9]{0,6})', data[offset:end])
        require(header is not None, 'record framing')
        length = int(header[2])
        require(length <= MAX_WIRE, 'wire bound')
        start, end = end + 1, end + 1 + length
        require(data[end:end + 5] == b'\nEND\n', 'record framing')
        records.append(Observation(header[1].decode(), data[start:end]))
        offset = end + 5
    require(tuple(record.site for record in records) == EXPECTED_SITES, 'event completeness')
    return records


def oracle_module():
    spec = importlib.util.spec_from_file_location('private_mime_oracle', ROOT / 'tests/mime_oracle.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def compare_observation(raw, parsed):
    try:
        return oracle_module().compare(raw, parsed)
    except Exception:
        raise Refused('parser disagreement') from None


def check_literal_input(raw):
    try:
        message = oracle_module().parse(raw)
        require(str(message['Subject']) == 'Unicode é 雪', 'literal input')
        for field, address in (('From', 'tester@example.com'), ('To', 'a@example.com')):
            require(len(message.get_all(field, [])) == 1, 'literal input')
            require([(a.display_name, a.addr_spec) for a in message[field].addresses] == [('', address)],
                    'literal input')
        require(len(message.get_all('Subject', [])) == 1, 'literal input')
        require(not any(message.get_all(h, []) for h in ('Cc', 'Bcc', 'In-Reply-To', 'References')),
                'literal input')
        require(not message.is_multipart() and message.get_content_type() == 'text/plain', 'literal input')
        require(message.get_content_charset() == 'utf-8', 'literal input')
        require(message.get_content_disposition() is None and message.get_filename() is None, 'literal input')
        require(message.get_content() == 'x' * 1048576, 'literal input')
        require(message.get_payload(decode=True) == b'x' * 1048576, 'literal input')
    except Exception:
        raise Refused('literal input') from None


def scenario_environment(work, imap_port, smtp_port, tls_helper, attach_helper):
    require(work.is_absolute() and stat.S_IMODE(work.stat().st_mode) == 0o700, 'private workspace')
    require(all(type(port) is int and 0 < port < 65536 for port in (imap_port, smtp_port)), 'fixture port')
    require(all(path.is_absolute() and path.is_file() and not path.is_symlink()
                for path in (tls_helper, attach_helper)), 'helper paths')
    return {
        'PATH': '/usr/bin:/bin', 'LC_ALL': 'C.UTF-8', 'TZ': 'UTC', 'BEND_NO_TELEMETRY': '1',
        'HOME': str(work / 'home'), 'TMPDIR': str(work / 'tmp'),
        'MAILBEND_EMAIL': 'tester@example.com', 'MAILBEND_APP_PASSWORD': 'test-app-pass-1234',
        'MAILBEND_IMAP_HOST': 'localhost', 'MAILBEND_IMAP_PORT': str(imap_port),
        'MAILBEND_SMTP_HOST': 'localhost', 'MAILBEND_SMTP_PORT': str(smtp_port),
        'MAILBEND_IMAP_CONNECT_IP': '127.0.0.1', 'MAILBEND_SMTP_CONNECT_IP': '127.0.0.1',
        'MAILBEND_SMTP_TLS_MODE': 'starttls', 'MAILBEND_CA_FILE': str(work / 'certs/ca.pem'),
        'MAILBEND_TIMEOUT_MS': '10000', 'MAILBEND_STATE_DIR': str(work / 'state'),
        'MAILBEND_TLS_HELPER': str(tls_helper), 'MAILBEND_ATTACH_HELPER': str(attach_helper),
        'MAILBEND_TYPESAFE': 'off',
    }


def check_equivalence(stock, observed):
    for result in (stock, observed):
        require(result['exit'] == 0, 'public exit')
        require(result['before'] == result['after'], 'mailbox mutation')
        require(result['received'] == [], 'transmitted composition')
        output = result['stdout'] + result['stderr']
        require(not any(marker in output for marker in (
            b'x' * 64, b'MB124 ', b'mime-observation:', b'Content-Transfer-Encoding:',
            b'test-app-pass-1234')), 'public disclosure')
        for command in result['commands']:
            require(set(command) == {'proto', 'line'}, 'command structure')
            require(not re.search(r'(?:^|\s)(?:DATA|APPEND|STORE|COPY|MOVE|EXPUNGE|'
                                  r'CREATE|DELETE|RENAME|SUBSCRIBE|UNSUBSCRIBE)(?:\s|$)',
                                  command['line'], re.I), 'protocol mutation')
    for key in ('exit', 'stdout', 'stderr', 'commands', 'before', 'after', 'received'):
        require(stock[key] == observed[key], 'stock equivalence')


def fixed_request():
    return json.dumps({'to': 'a@example.com', 'subject': 'Unicode é 雪',
                       'body': 'x' * 1048576, 'dry_run': True}).encode()


def check_preview(result, wire_size=None):
    require(result['exit'] == 0 and result['stderr'] == CA_WARNING, 'successful public request')
    try:
        value = json.loads(result['stdout'])
        require(type(value) is dict and set(value) == {'dry_run', 'imap'} and
                value['dry_run'] is True and type(value['imap']) is list and len(value['imap']) == 1,
                'size-only preview')
        match = re.fullmatch(r'a1 APPEND "Drafts" \(\\Draft \\Seen\) <([1-9][0-9]*) bytes>',
                             value['imap'][0])
        require(match is not None and 1048576 < int(match[1]) <= MAX_WIRE, 'size-only preview')
        require(wire_size is None or int(match[1]) == wire_size, 'preview byte count')
    except (TypeError, ValueError, KeyError):
        raise Refused('size-only preview') from None


def artifact(record, executable=True):
    require(type(record) is dict and set(record) == {'path', 'size', 'sha256'}, 'artifact record')
    require(type(record['size']) is int and 0 < record['size'] <= 256 * 1024 * 1024,
            'artifact bound')
    require(type(record['sha256']) is str and re.fullmatch('[0-9a-f]{64}', record['sha256']),
            'artifact digest')
    path = Path(record['path'])
    require(path.is_absolute(), 'artifact path')
    data, mode = read_regular(path, record['size'])
    require(len(data) == record['size'] and sha(data) == record['sha256'], 'artifact identity')
    require(not executable or mode & 0o111, 'artifact executable')
    return path


def runtime_bundle(path, approved_sha256, control):
    require(type(approved_sha256) is str and re.fullmatch('[0-9a-f]{64}', approved_sha256),
            'reviewed runtime manifest required')
    encoded, _ = read_regular(path, 131072)
    require(sha(encoded) == approved_sha256, 'runtime manifest identity')
    bundle = json.loads(encoded)
    require(type(bundle) is dict and set(bundle) == {
        'version', 'scenario', 'source_commit', 'source_tree', 'driver_sha256', 'export',
        'artifacts', 'build_identities', 'bindings'}, 'runtime manifest schema')
    require(bundle['version'] == 1 and bundle['scenario'] == SCENARIO and
            bundle['source_commit'] == BASE and bundle['source_tree'] == BASE_TREE,
            'runtime source identity')
    require(sha(read_regular(ROOT / NEW_FILES[0], MAX_TEST_SOURCE)[0]) == bundle['driver_sha256'],
            'runtime driver identity')
    require(set(bundle['artifacts']) == RUNTIME_ARTIFACTS and
            set(bundle['build_identities']) == BUILD_IDENTITIES, 'runtime artifact inventory')
    binaries = {name: artifact(record) for name, record in bundle['artifacts'].items()}
    for name, record in bundle['build_identities'].items():
        artifact(record, executable=name not in {'bend_base', 'provenance'})
    require(binaries['python'].resolve() == Path(sys.executable).resolve() and
            binaries['date'].resolve() == Path('/bin/date').resolve() and
            binaries['dirname'].resolve() == Path('/usr/bin/dirname').resolve() and
            binaries['git'].resolve() == Path('/usr/bin/git').resolve(), 'runtime tool selection')
    files, modes = baseline(control)
    export_info = bundle['export']
    require(type(export_info) is dict and set(export_info) == {'path', 'manifest_sha256'},
            'export identity record')
    export = Path(export_info['path'])
    require(export.is_absolute() and not export.is_symlink() and
            stat.S_IMODE(export.stat().st_mode) == 0o700 and export.stat().st_uid == os.getuid(),
            'private export')
    encoded, _ = read_regular(export / 'manifest.json', 262144)
    require(sha(encoded) == export_info['manifest_sha256'], 'export manifest identity')
    manifest = json.loads(encoded)
    require(manifest['base'] == BASE and manifest['tree'] == BASE_TREE and
            manifest['candidate_files'] == {name: sha(read_regular(ROOT / name, MAX_TEST_SOURCE)[0])
                                            for name in NEW_FILES}, 'export source identity')
    require(manifest['files'] == {name: {'mode': modes[name], 'sha256': sha(data)}
                                  for name, data in files.items()}, 'export baseline identity')
    module, _ = read_regular(export / 'source' / NEW_FILES[1], MAX_TEST_SOURCE)
    tools = transform(files['src/tools.bend'].decode()).encode()
    require(sha(module) == manifest['module_sha256'] and sha(tools) == manifest['tools_sha256'],
            'generated source identity')
    check_export(export / 'source', files, modes, tools, module)
    template = read_regular(ROOT / NEW_FILES[1], MAX_TEST_SOURCE)[0].decode()
    token_match = re.search(r'def context_token\(\) -> String:\n  "([0-9a-f]{64})"', module.decode())
    require(token_match is not None, 'private context identity')
    token = token_match[1]
    for marker, value in {
        'False{} # @PREPARED@': 'True{} # private generated experiment',
        '@CONTEXT_PATH@': str(export / 'context'), '@CONTEXT_TOKEN@': token,
        '@CAPTURE_PATH@': str(export / 'capture'),
    }.items():
        template = template.replace(marker, value)
    require(template.encode() == module, 'observer template identity')
    require(bundle['bindings'] == {
        'stock_tree': BASE_TREE, 'observed_tools': sha(tools), 'observed_module': sha(module),
        'mime_oracle': sha(files['tests/mime-oracle.bend']),
        'native_tree': git('rev-parse', BASE + ':native', control=control).decode().strip(),
    }, 'build source bindings')
    require(not (export / 'context').exists() and not (export / 'source/bin').exists(),
            'unarmed clean export')
    capture, mode = read_regular(export / 'capture', 0)
    require(capture == b'' and stat.S_IMODE(mode) == 0o600, 'private empty capture')
    oracle_module().check_python_runtime(lambda _name, ok, _detail='': require(ok, 'Python MIME runtime'))
    return bundle, binaries, export, token, files, modes, module


class RuntimeControl:
    def __init__(self):
        self.deadline = time.monotonic() + 600
        self.cancelled = False
        self.handlers = {}

    def __enter__(self):
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            self.handlers[number] = signal.signal(number, self.cancel)
        return self

    def cancel(self, _number, _frame):
        self.cancelled = True

    def check(self, deadline):
        require(not self.cancelled, 'runtime cancelled')
        require(time.monotonic() < min(deadline, self.deadline), 'runtime deadline')

    def __exit__(self, *_):
        for number, handler in self.handlers.items():
            signal.signal(number, handler)


def child_limits():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_AS, (3 * 1024 ** 3, 3 * 1024 ** 3))
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_CAPTURE, MAX_CAPTURE))


def bounded_extend(buffer, chunk, limit):
    require(len(buffer) + len(chunk) <= limit, 'subprocess output bound')
    buffer.extend(chunk)


def readiness(data):
    match = re.fullmatch(rb'READY imap=([0-9]{1,5}) smtp=([0-9]{1,5})\n', data)
    require(match is not None and all(0 < int(port) < 65536 for port in match.groups()),
            'fixture readiness')
    return tuple(int(port) for port in match.groups())


class Child:
    def __init__(self, command, environment, cwd, control, data=b'', output_limit=65536):
        self.control, self.data, self.limit = control, memoryview(data), output_limit
        self.stdout, self.stderr = bytearray(), bytearray()
        self.proc = None
        self.control.check(self.control.deadline)
        try:
            self.proc = subprocess.Popen(command, cwd=cwd, env=environment,
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, start_new_session=True,
                                         preexec_fn=child_limits, umask=0o077, bufsize=0)
            for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
                os.set_blocking(stream.fileno(), False)
        except BaseException:
            self.close()
            raise

    def exited(self):
        if self.proc.returncode is not None:
            return True
        return os.waitid(os.P_PID, self.proc.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG) is not None

    def stop(self):
        if self.proc is None or self.proc.returncode is not None:
            return
        try:
            os.waitid(os.P_PID, self.proc.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG)
        except ChildProcessError:
            raise Refused('child ownership lost') from None
        with contextlib.suppress(ProcessLookupError):
            os.killpg(self.proc.pid, signal.SIGTERM)
        deadline = time.monotonic() + 1
        while not self.exited() and time.monotonic() < deadline:
            time.sleep(0.02)
        with contextlib.suppress(ProcessLookupError):
            os.killpg(self.proc.pid, signal.SIGKILL)
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            raise Refused('child cleanup deadline') from None

    def pump(self, seconds, ready=False):
        deadline = time.monotonic() + seconds
        with selectors.DefaultSelector() as selector:
            for stream, label in ((self.proc.stdout, 'stdout'), (self.proc.stderr, 'stderr')):
                if not stream.closed:
                    selector.register(stream, selectors.EVENT_READ, label)
            if not self.proc.stdin.closed:
                if self.data:
                    selector.register(self.proc.stdin, selectors.EVENT_WRITE, 'stdin')
                else:
                    self.proc.stdin.close()
            while selector.get_map() or not self.exited():
                self.control.check(deadline)
                if self.exited():
                    self.stop()
                for key, _ in selector.select(0.05):
                    if key.data == 'stdin':
                        try:
                            written = os.write(key.fd, self.data[:65536])
                            self.data = self.data[written:]
                        except BrokenPipeError:
                            self.data = self.data[:0]
                        except BlockingIOError:
                            continue
                        if not self.data:
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                    else:
                        try:
                            chunk = os.read(key.fd, 65536)
                        except BlockingIOError:
                            continue
                        if not chunk:
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                        else:
                            buffer = self.stdout if key.data == 'stdout' else self.stderr
                            bounded_extend(buffer, chunk, self.limit)
                if ready and b'\n' in self.stdout:
                    require(not self.exited(), 'fixture startup exit')
                    return readiness(bytes(self.stdout))
            self.stop()
        require(not ready, 'fixture exited before ready')
        return {'exit': self.proc.returncode, 'stdout': bytes(self.stdout), 'stderr': bytes(self.stderr)}

    def close(self):
        try:
            self.stop()
        finally:
            if self.proc is not None:
                for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
                    if stream is not None:
                        stream.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def checked_child(command, environment, cwd, control, data=b'', seconds=30, output_limit=65536):
    with Child(command, environment, cwd, control, data, output_limit) as child:
        result = child.pump(seconds)
    require(result['exit'] == 0, 'subprocess failed')
    return result


def fixture_environment(work):
    return {'PATH': '/usr/bin:/bin', 'HOME': str(work / 'home'), 'TMPDIR': str(work / 'tmp'),
            'LC_ALL': 'C.UTF-8', 'TZ': 'UTC', 'BEND_NO_TELEMETRY': '1', 'OPENSSL_CONF': '/dev/null'}


def certificates(work, binaries, control):
    certs = work / 'certs'
    certs.mkdir(mode=0o700)
    for name in ('ca-key.pem', 'ca.pem', 'server-key.pem', 'server.csr', 'server.pem'):
        private_write(certs / name, b'')
    private_write(certs / 'server.ext', b'subjectAltName=DNS:localhost\n')
    commands = [
        ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-keyout', 'ca-key.pem',
         '-out', 'ca.pem', '-subj', '/CN=MailBend observation test CA'],
        ['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'server-key.pem',
         '-out', 'server.csr', '-subj', '/CN=localhost'],
        ['x509', '-req', '-in', 'server.csr', '-CA', 'ca.pem', '-CAkey', 'ca-key.pem',
         '-CAcreateserial', '-days', '1', '-out', 'server.pem', '-extfile', 'server.ext'],
    ]
    for command in commands:
        checked_child([str(binaries['openssl']), *command], fixture_environment(work), certs, control)
    return certs


def private_binary(source, destination):
    data, mode = read_regular(source, 64 * 1024 * 1024)
    require(mode & 0o111, 'private executable source')
    private_write(destination, data)
    destination.chmod(0o700)


def json_file(path):
    data, _ = read_regular(path, MAX_CAPTURE)
    return json.loads(data)


def json_lines(path):
    data, _ = read_regular(path, MAX_CAPTURE)
    return [json.loads(line) for line in data.splitlines() if line]


def run_side(name, source, work, binaries, certs, control, arm=None):
    case = work / name
    case.mkdir(mode=0o700)
    for child in ('home', 'tmp', 'state', 'certs'):
        (case / child).mkdir(mode=0o700)
    for leaf in ('ca.pem', 'server.pem', 'server-key.pem'):
        private_write(case / 'certs' / leaf, read_regular(certs / leaf, 65536)[0])
    for leaf in ('state.json', 'commands.jsonl', 'received.jsonl'):
        private_write(case / leaf, b'')
    fixture = source / 'tests/fixtures/mailbox.json'
    command = [str(binaries['python']), '-I', str(source / 'tests/fake_mail_server.py'),
               '--bind-host', '127.0.0.1', '--certdir', str(case / 'certs'), '--fixture', str(fixture),
               '--state', str(case / 'state.json'), '--log', str(case / 'commands.jsonl'),
               '--composed', str(case / 'received.jsonl')]
    with Child(command, fixture_environment(case), case, control, output_limit=4096) as server:
        imap, smtp = server.pump(10, ready=True)
        before = json_file(case / 'state.json')
        require(sha(json.dumps(before, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode())
                == INITIAL_STATE_SHA256, 'initial fixture state')
        environment = scenario_environment(case, imap, smtp, binaries['tls_helper'], binaries['attach_helper'])
        try:
            if arm is not None:
                context, token = arm
                private_write(context, token.encode())
            with Child([str(binaries['shell']), str(source / 'scripts/mailbend'),
                        'call', 'mail_save_draft', '-'], environment, case, control,
                       fixed_request(), 65536) as client:
                result = client.pump(120)
        finally:
            if arm is not None:
                arm[0].unlink(missing_ok=True)
        server.stop()
        stopped = server.pump(5)
        require(stopped['exit'] == 0 and stopped['stderr'] == b'' and
                readiness(stopped['stdout']) == (imap, smtp),
                'fixture diagnostics')
    result.update(before=before, after=json_file(case / 'state.json'),
                  commands=json_lines(case / 'commands.jsonl'), received=json_lines(case / 'received.jsonl'))
    check_preview(result)
    check_equivalence(result, result)
    return result


def captured_controls(frame, raw, parsed):
    changed = copy.deepcopy(parsed)
    changed['parts'][0]['text'] += 'changed'
    expect_refusal(lambda: compare_observation(raw, changed), 'parser disagreement')
    expect_refusal(lambda: read_records(b''), 'event completeness')
    expect_refusal(lambda: check_literal_input(raw[:-1] + b'y'), 'literal input')
    expect_refusal(lambda: read_records(frame[:-1]), 'record framing')


def run_reviewed(manifest_path, approved_sha256):
    """Future internal entry point. The caller must obtain runtime/resource release.

    approved_sha256 must name the independently reviewed artifact/reuse decision.
    No CLI action calls this function in the source-preparation candidate.
    """
    old_umask = os.umask(0o077)
    try:
        with RuntimeControl() as control:
            export = None
            installed = False
            try:
                bundle, binaries, export, token, files, modes, module = runtime_bundle(
                    manifest_path, approved_sha256, control)
                with tempfile.TemporaryDirectory(prefix='runtime-', dir=export) as directory:
                    work = Path(directory)
                    for leaf in ('home', 'tmp', 'helpers'):
                        (work / leaf).mkdir(mode=0o700)
                    for name in ('tls_helper', 'attach_helper', 'mime_oracle'):
                        destination = work / 'helpers' / name
                        private_binary(binaries[name], destination)
                        require(sha(read_regular(destination, 64 * 1024 * 1024)[0]) ==
                                bundle['artifacts'][name]['sha256'], 'private helper identity')
                        binaries[name] = destination
                    source = export / 'source'
                    (source / 'bin').mkdir(mode=0o700)
                    installed = True
                    certs = certificates(work, binaries, control)
                    results = []
                    for name in ('stock', 'observed'):
                        core = source / 'bin/mailbend-core'
                        private_binary(binaries[name + '_core'], core)
                        require(sha(read_regular(core, 64 * 1024 * 1024)[0]) ==
                                bundle['artifacts'][name + '_core']['sha256'], 'private core identity')
                        arm = (export / 'context', token) if name == 'observed' else None
                        results.append(run_side(name + '-case', source, work, binaries, certs, control, arm))
                        core.unlink()
                        if name == 'stock':
                            require(read_regular(export / 'capture', 0)[0] == b'', 'stock capture absent')
                    frame, mode = read_regular(export / 'capture', MAX_CAPTURE)
                    require(stat.S_IMODE(mode) == 0o600, 'capture file mode')
                    raw = read_records(frame)[0].wire
                    check_preview(results[1], len(raw))
                    check_equivalence(*results)
                    check_literal_input(raw)
                    parsed_run = checked_child([str(binaries['mime_oracle'])], fixture_environment(work),
                                               work, control, base64.b64encode(raw) + b'\n', 120, MAX_CAPTURE)
                    require(parsed_run['stderr'] == b'' and len(parsed_run['stdout'].splitlines()) == 1,
                            'MIME observer framing')
                    parsed = json.loads(parsed_run['stdout'])
                    compare_observation(raw, parsed)
                    captured_controls(frame, raw, parsed)
                    return {'scenario': SCENARIO, 'events': 1, 'public_equivalence': 'pass',
                            'literal_input': 'pass', 'parser_comparison': 'pass', 'negative_controls': 4}
            finally:
                if export is not None:
                    (export / 'context').unlink(missing_ok=True)
                    (export / 'capture').unlink(missing_ok=True)
                    private_write(export / 'capture', b'')
                    if installed:
                        shutil.rmtree(export / 'source/bin')
                    check_export(export / 'source', files, modes,
                                 transform(files['src/tools.bend'].decode()).encode(), module)
    except Refused:
        raise
    except Exception:
        raise Refused('runtime failed') from None
    finally:
        os.umask(old_umask)


def dry_plan():
    return {'scenario': SCENARIO, 'runtime_cli_available': False, 'source_commit': BASE,
            'source_tree': BASE_TREE, 'request': 'mail_save_draft via CLI stdin; one MiB of x; dry_run=true',
            'required_artifacts': sorted(RUNTIME_ARTIFACTS), 'required_build_identities': sorted(BUILD_IDENTITIES),
            'bounds': {'total_seconds': 600, 'client_seconds': 120, 'parser_seconds': 120,
                       'server_start_seconds': 10, 'child_cleanup_seconds': 6,
                       'client_output_bytes_per_stream': 65536, 'capture_bytes': MAX_CAPTURE,
                       'child_address_space_bytes': 3 * 1024 ** 3},
            'pending': ['independent driver source review', 'reviewed artifact manifest and reuse decision',
                        'observed core and MIME observer build receipts', 'generated-code review',
                        'runtime and resource release', 'actual lifecycle controls and scenario execution']}


def expect_refusal(action, category):
    try:
        action()
    except Refused as error:
        require(str(error) == category, 'control category')
    else:
        raise Refused('control missed')


def preparation_controls():
    (ROOT / 'build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='mime-preparation-control-', dir=ROOT / 'build') as directory:
        fixture = Path(directory) / 'source'
        git('worktree', 'add', '--detach', str(fixture), BASE)
        try:
            for name in NEW_FILES:
                private_write(fixture / name, read_regular(ROOT / name, MAX_TEST_SOURCE)[0])
            target = fixture / 'README.md'
            original = git('show', BASE + ':README.md')
            for kind, category in (('fifo', 'source file type'), ('directory', 'source file type'),
                                   ('symlink', 'source file type'), ('oversized', 'source file bound')):
                target.unlink()
                try:
                    if kind == 'fifo':
                        os.mkfifo(target, 0o600)
                    elif kind == 'directory':
                        target.mkdir(mode=0o700)
                    elif kind == 'symlink':
                        target.symlink_to('LICENSE')
                    else:
                        private_write(target, original + b'x')
                    try:
                        result = subprocess.run(
                            [sys.executable, '-I', str(fixture / NEW_FILES[0]), 'prepare'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12,
                            env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C.UTF-8'})
                    except subprocess.TimeoutExpired:
                        raise Refused('preparation control timeout') from None
                    require(result.returncode == 1 and result.stdout == b'' and result.stderr ==
                            ('FAIL cli-stdin-one-mib-draft: ' + category + '\n').encode(),
                            'preparation refusal control')
                    require(not (fixture / 'build').exists(), 'preparation wrote before refusal')
                finally:
                    if kind == 'directory':
                        target.rmdir()
                    else:
                        target.unlink()
                    private_write(target, original)
                    target.chmod(0o644)
        finally:
            git('worktree', 'remove', '--force', str(fixture))
    print('PASS public preparation rejects FIFO/directory/symlink/oversized inputs within deadline')


def descriptor_cleanup_controls():
    real_open, real_fdopen = os.open, os.fdopen
    for replacement in (True, False):
        with tempfile.TemporaryDirectory(prefix='mime-descriptor-control-') as directory:
            target = Path(directory) / 'source'
            private_write(target, b'fixed source')
            descriptors = []
            closed = False

            def open_at_boundary(path, flags):
                require(path == target, 'descriptor control path')
                if replacement:
                    target.unlink()
                    target.mkdir()
                descriptor = real_open(path, flags)
                descriptors.append(descriptor)
                return descriptor

            def wrap_at_boundary(*args, **kwargs):
                if not replacement:
                    raise OSError(errno.EINVAL, 'synthetic wrapper refusal')
                return real_fdopen(*args, **kwargs)

            try:
                failure = None
                with patch.object(os, 'open', side_effect=open_at_boundary), \
                     patch.object(os, 'fdopen', side_effect=wrap_at_boundary):
                    try:
                        read_regular(target, 12)
                    except (Refused, OSError) as error:
                        failure = error
                require(failure is not None, 'replacement refusal')
                require(len(descriptors) == 1, 'descriptor control setup')
                try:
                    os.fstat(descriptors[0])
                except OSError as error:
                    closed = error.errno == errno.EBADF
                require(closed, 'replacement descriptor leaked')
                if replacement:
                    require(isinstance(failure, Refused) and str(failure) == 'source file type',
                            'replacement refusal category')
                else:
                    require(isinstance(failure, OSError) and failure.errno == errno.EINVAL,
                            'wrapper refusal category')
            finally:
                if descriptors and not closed:
                    os.close(descriptors[0])
    print('PASS directory replacement and wrapper failure refuse with closed descriptors')


def lifecycle_source_controls():
    with patch.object(subprocess, 'Popen', side_effect=Refused('source control attempted a launch')):
        plan = dry_plan()
        require(plan['runtime_cli_available'] is False and plan['scenario'] == SCENARIO, 'dry plan')
        request = json.loads(fixed_request())
        require(set(request) == {'to', 'subject', 'body', 'dry_run'} and
                request['to'] == 'a@example.com' and request['subject'] == 'Unicode é 雪' and
                request['dry_run'] is True and request['body'] == 'x' * 1048576, 'fixed request')
        good = {'exit': 0, 'stderr': CA_WARNING, 'stdout': json.dumps(
            {'dry_run': True, 'imap': ['a1 APPEND "Drafts" (\\Draft \\Seen) <1090000 bytes>']}).encode()}
        check_preview(good, 1090000)
        for value in ({}, {'dry_run': True, 'imap': []}, {'dry_run': False, 'imap': []},
                      {'dry_run': True, 'imap': ['a1 APPEND "Drafts" (\\Draft \\Seen) <5 bytes>']},
                      {'dry_run': True, 'imap': ['raw body'], 'wire': 'forbidden'}):
            expect_refusal(lambda: check_preview({**good, 'stdout': json.dumps(value).encode()}),
                           'size-only preview')
        expect_refusal(lambda: check_preview(good, 1090001), 'preview byte count')
        expect_refusal(lambda: check_preview({**good, 'exit': 1}), 'successful public request')
        expect_refusal(lambda: check_preview({**good, 'stderr': b''}), 'successful public request')
        require(readiness(b'READY imap=12345 smtp=12346\n') == (12345, 12346), 'readiness control')
        for line in (b'READY imap=1 smtp=2', b'READY imap=0 smtp=2\n',
                     b'READY imap=65536 smtp=2\n', b'READY imap=1 smtp=2\nextra'):
            expect_refusal(lambda: readiness(line), 'fixture readiness')
        buffer = bytearray()
        bounded_extend(buffer, b'abc', 3)
        expect_refusal(lambda: bounded_extend(buffer, b'x', 3), 'subprocess output bound')
        with tempfile.TemporaryDirectory(prefix='mime-artifact-control-') as directory:
            path = Path(directory) / 'synthetic-source'
            private_write(path, b'fixed')
            record = {'path': str(path), 'size': 5, 'sha256': sha(b'fixed')}
            require(artifact(record, executable=False) == path, 'artifact control')
            expect_refusal(lambda: artifact({**record, 'sha256': '0' * 64}, executable=False),
                           'artifact identity')
    print('PASS lifecycle source contracts; process launch disabled in these controls')


def self_test():
    lifecycle_source_controls()
    descriptor_cleanup_controls()
    preparation_controls()
    source = (ROOT / 'src/tools.bend').read_text()
    changed = transform(source)
    require(NEW_DRAFT in changed and changed.count('MimeObservation.observe(') == 1, 'draft observer')
    require(changed.count('M.compose(') == 3, 'same composition sites')
    require(changed.replace(IMPORT + OBSERVER_IMPORT, IMPORT).replace(NEW_DRAFT, OLD_DRAFT) == source,
            'only reviewed transformation')
    for changed_source in (source + '\n', source.replace(SITES[2], ''), source + SITES[2]):
        expect_refusal(lambda: transform(changed_source), 'source hash')
    production = {str(path.relative_to(ROOT)): path.read_bytes() for path in (ROOT / 'src').glob('*.bend')}
    production['main.bend'] = (ROOT / 'main.bend').read_bytes()
    inventory(production)
    unknown = dict(production)
    unknown['src/extra.bend'] = b'import ./mime.bend as X\n'
    expect_refusal(lambda: inventory(unknown), 'MIME import inventory')
    unknown = dict(production)
    unknown['src/tools.bend'] += b'\nM.compose(unreviewed, unreviewed)\n'
    expect_refusal(lambda: inventory(unknown), 'composition inventory')
    unknown = dict(production)
    unknown['main.bend'] += b'\nimport ./src/mime.bend as X\n'
    expect_refusal(lambda: inventory(unknown), 'unknown MIME import')
    print('PASS guarded draft transformation and three drift controls')
    print('PASS complete production import/site inventory and unknown-site controls')

    raw = ('From: tester@example.com\r\nTo: a@example.com\r\nSubject: Unicode é 雪\r\n'
           'MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n'
           'Content-Transfer-Encoding: 7bit\r\n\r\n').encode() + b'x' * 1048576
    frame = b'MB124 draft ' + str(len(raw)).encode() + b'\n' + raw + b'\nEND\n'
    require(read_records(frame) == [Observation('draft', raw)], 'record bytes')
    expect_refusal(lambda: read_records(b''), 'event completeness')
    expect_refusal(lambda: read_records(frame + frame), 'event completeness')
    for broken in (frame[:-1], frame.replace(b'MB124 draft', b'MB124 unknown', 1), b'garbage',
                   frame + b'junk', b'MB124 draft 2\na\nEND\n'):
        expect_refusal(lambda: read_records(broken), 'record framing')
    expect_refusal(lambda: read_records(b'MB124 draft 1572865\n'), 'wire bound')
    expect_refusal(lambda: read_records(b' ' * (MAX_CAPTURE + 1)), 'capture bound')
    print('PASS original-byte framing, missing/duplicate/unknown/truncated/oversized controls')

    check_literal_input(raw)
    expect_refusal(lambda: check_literal_input(raw[:-1] + b'y'), 'literal input')
    parsed = {
        'content_type': 'text/plain', 'disposition': '', 'charset': 'utf-8', 'boundary': '',
        'headers': [{'name': n, 'value': v} for n, v in (
            ('from', 'tester@example.com'), ('to', 'a@example.com'), ('subject', 'Unicode é 雪'),
            ('mime-version', '1.0'), ('content-type', 'text/plain; charset=utf-8'),
            ('content-transfer-encoding', '7bit'))],
        'parts': [{'content_type': 'text/plain', 'filename': '', 'disposition': '',
                   'charset': 'utf-8', 'text': 'x' * 1048576,
                   'data': base64.b64encode(b'x' * 1048576).decode()}],
    }
    compare_observation(raw, parsed)
    corrupt = copy.deepcopy(parsed)
    corrupt['parts'][0]['text'] = 'changed'
    expect_refusal(lambda: compare_observation(raw, corrupt), 'parser disagreement')
    corrupt = copy.deepcopy(parsed)
    corrupt['headers'][0]['value'] = 'private-control@example.invalid'
    expect_refusal(lambda: compare_observation(raw, corrupt), 'parser disagreement')
    print('PASS independent literal input and sanitized parser-disagreement controls')

    stock = {'exit': 0, 'stdout': b'{"dry_run":true}\n', 'stderr': b'',
             'commands': [{'proto': 'imap', 'line': 'a1 CAPABILITY'}],
             'before': {'mailboxes': {}, 'sent': []}, 'after': {'mailboxes': {}, 'sent': []},
             'received': []}
    check_equivalence(stock, copy.deepcopy(stock))
    for key, value, category in (
        ('stdout', b'changed', 'stock equivalence'), ('stderr', b'changed', 'stock equivalence'),
        ('exit', 1, 'public exit'), ('commands', [], 'stock equivalence'),
        ('after', {'mailboxes': {}, 'sent': ['changed']}, 'mailbox mutation'),
        ('received', ['changed'], 'transmitted composition'),
        ('commands', [{'proto': 'imap', 'line': 'a1 UID STORE 1 +FLAGS (\\Seen)'}], 'protocol mutation'),
        ('stdout', b'MB124 draft', 'public disclosure')):
        other = copy.deepcopy(stock)
        other[key] = value
        expect_refusal(lambda: check_equivalence(stock, other), category)
    print('PASS exact output, ordered commands, state and zero-mutation controls')

    with tempfile.TemporaryDirectory(prefix='mime-observation-control-') as directory:
        work = Path(directory)
        helper = work / 'synthetic-helper'
        private_write(helper, b'not executable; no product code')
        environment = scenario_environment(work, 12345, 12346, helper, helper)
        require(environment['HOME'] == str(work / 'home') and
                environment['MAILBEND_TYPESAFE'] == 'off' and
                not any('PROXY' in key or key.endswith('_KEY_FILE') or key.endswith('_PASSWORD_FILE')
                        for key in environment), 'environment allowlist')
        expect_refusal(lambda: scenario_environment(work, 0, 12346, helper, helper), 'fixture port')
        require(stat.S_IMODE(helper.stat().st_mode) == 0o600, 'private file mode')
    print('PASS private files and explicit synthetic environment')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('self-test', 'prepare', 'plan'), nargs='?', default='self-test')
    args = parser.parse_args()
    old_umask = os.umask(0o077)
    try:
        if args.action == 'self-test':
            self_test()
        elif args.action == 'plan':
            print(json.dumps(dry_plan(), indent=2))
        else:
            print('Prepared unarmed source export: ' + str(prepare()))
    finally:
        os.umask(old_umask)


if __name__ == '__main__':
    try:
        main()
    except Refused as error:
        print('FAIL cli-stdin-one-mib-draft: ' + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        print('FAIL cli-stdin-one-mib-draft: source preparation failed', file=sys.stderr)
        sys.exit(1)
