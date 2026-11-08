#!/usr/bin/env python3
"""Fixed #124 hosted stock-oracle C emission. Stop before compilation or mail."""
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import time

BASE = '1970639fcfcc7589bc62e95adf8d49341b378136'
BASE_TREE = 'd662d9f9a986cc01a1a16ef0326cdc556a84e68f'
BRANCH = 'refs/heads/validation/mime-observation-124-emission-1970639'
ADDITIONS = {'.github/workflows/mime-observation.yml', 'tests/mime-observation-hosted.py',
             'tests/mime-observation-controls.py', 'tests/test-mime-observation.py',
             'tests/mime-observation.bend'}
CONTROL_SHA = '5dcabb0346781864738a974ec983d090cd6d857f2a773c9a70ef547324455445'
DRIVER_SHA = '5ec8b9178e0fd0bdb6452d4330b97bd14d4f8a0a72049a7a4e6033938e54b67f'
TEMPLATE_SHA = '9d679d4ad934e22982c9e46393c90a249e82f552dbba7af7c32ae9c31bf17114'
BEND_SHA = 'af967c7c37aced4491e0f4344e3bb9de837c2c89b7519f7e0b8c71935be1840a'
ARCHIVE_SHA = '63039d1a119f716767ac5a7d8fe0717cfacf219c6c253c35192148e0dade722f'
MAX_FILE = 512 * 1024 * 1024
MAX_LOG = 16 * 1024 * 1024
FLOOR = 8589934592
CANCELLED = 0
CLEANUP_UNCERTAIN = False


class Refused(Exception):
    pass


class CleanupUncertain(Refused):
    pass


def need(ok, category):
    if not ok:
        raise Refused(category)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_file(path, limit=MAX_FILE):
    path = Path(path)
    before = path.lstat()
    need(stat.S_ISREG(before.st_mode) and before.st_size <= limit, 'input type or size')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened = os.fstat(fd)
        need(stat.S_ISREG(opened.st_mode) and (opened.st_dev, opened.st_ino) ==
             (before.st_dev, before.st_ino) and opened.st_size <= limit, 'input replacement')
        chunks, size = [], 0
        while True:
            part = os.read(fd, min(1048576, limit + 1 - size))
            if not part:
                break
            chunks.append(part)
            size += len(part)
            need(size <= limit, 'input bound')
        after = os.fstat(fd)
        need(size == opened.st_size and (after.st_size, after.st_mtime_ns) ==
             (opened.st_size, opened.st_mtime_ns), 'input changed during read')
        return b''.join(chunks)
    finally:
        os.close(fd)


def identity(path):
    path = Path(path)
    original = path.lstat()
    resolved = path.resolve(strict=True)
    data = read_file(resolved)
    need(path.resolve(strict=True) == resolved, 'input resolution changed')
    return {'path': str(path), 'resolved': str(resolved), 'size': len(data),
            'sha256': digest(data), 'path_mode': oct(stat.S_IMODE(original.st_mode)),
            'target_mode': oct(stat.S_IMODE(resolved.stat().st_mode)),
            'symlink_target': os.readlink(path) if path.is_symlink() else None}


def private_dir(path):
    path = Path(path)
    need(path.is_absolute() and path.resolve(strict=True) == path, 'private directory alias')
    for parent in (path, *path.parents):
        need(stat.S_ISDIR(parent.lstat().st_mode), 'private directory alias')
    info = path.lstat()
    need(stat.S_IMODE(info.st_mode) == 0o700 and info.st_uid == os.getuid(), 'private directory')


def write_new(path, value):
    private_dir(path.parent)
    encoded = (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(encoded)


def utc():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def changed_signal(number, _frame):
    global CANCELLED
    CANCELLED = number


def terminal_signal(number, _frame):
    global CANCELLED
    CANCELLED = number
    raise SystemExit(1)


def arm_finalization():
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, terminal_signal)
    checkpoint()


def checkpoint():
    if CLEANUP_UNCERTAIN:
        raise CleanupUncertain('prior cleanup uncertain')
    need(not CANCELLED, 'cancelled')


def supervise(argv, out, cwd, environment, seconds, commands, log_limit=None):
    """Retained owned-child protocol, with cleanup inside one absolute budget."""
    global CLEANUP_UNCERTAIN
    checkpoint()
    log_limit = MAX_LOG if log_limit is None else log_limit
    private_dir(out)
    stdout, stderr = out / 'stdout', out / 'stderr'
    streams, child = [], None
    start = time.monotonic()
    deadline = start + seconds + 35
    result = {'argv': argv, 'start': utc(), 'status': 'uncertain',
              'timeout_seconds': seconds, 'kill_grace_seconds': 30,
              'supervisor_budget_seconds': seconds + 35}
    commands.append(result)
    write_new(out / 'start.json', result)
    try:
        for path in (stdout, stderr):
            streams.append(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
        try:
            child = subprocess.Popen(argv, cwd=cwd, env=environment,
                                     stdin=subprocess.DEVNULL, stdout=streams[0], stderr=streams[1],
                                     close_fds=True, start_new_session=True, umask=0o077)
        except OSError:
            raise Refused('command startup failed') from None
        need(os.getpgid(child.pid) == child.pid, 'child session ownership')
        while True:
            checkpoint()
            need(time.monotonic() < deadline, 'supervisor deadline')
            for path in (stdout, stderr):
                need(path.stat().st_size <= log_limit, 'compiler log bound')
            for path in out.iterdir():
                need(not path.is_symlink(), 'stage artifact type')
                if path.is_file():
                    need(path.stat().st_size <= MAX_FILE, 'stage artifact bound')
            event = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if event is not None:
                break
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    finally:
        cleanup_ok = time.monotonic() < deadline
        if child is not None:
            if child.returncode is None:
                # An unreaped direct child reserves the group identity. Never signal it after reap.
                for sig, pause in ((signal.SIGTERM, 1), (signal.SIGKILL, 0)):
                    try:
                        os.killpg(child.pid, sig)
                    except OSError as error:
                        if error.errno != errno.ESRCH:
                            cleanup_ok = False
                    if pause:
                        remaining = deadline - time.monotonic()
                        if remaining < pause:
                            cleanup_ok = False
                        time.sleep(max(0, min(pause, remaining)))
                try:
                    result['exit'] = child.wait(timeout=max(0, min(5, deadline - time.monotonic())))
                except (subprocess.TimeoutExpired, OSError):
                    cleanup_ok = False
                    result['exit'] = None
            else:
                cleanup_ok = False
                result['exit'] = child.returncode
            result['leader_reaped'] = child.returncode is not None
            result['group_completion'] = 'unreaped-leader'
            if result['leader_reaped']:
                probe_deadline = min(deadline, time.monotonic() + 5)
                while True:
                    if time.monotonic() >= probe_deadline:
                        result['group_completion'] = 'surviving-group-at-deadline'
                        break
                    try:
                        os.killpg(child.pid, 0)
                    except OSError as error:
                        result['group_completion'] = ('probe-deadline' if time.monotonic() >= probe_deadline
                            else 'absent-ESRCH' if error.errno == errno.ESRCH else 'probe-error')
                        break
                    time.sleep(min(0.05, max(0, probe_deadline - time.monotonic())))
            cleanup_ok = cleanup_ok and result['group_completion'] == 'absent-ESRCH'
        for fd in streams:
            try:
                os.close(fd)
            except OSError:
                cleanup_ok = False
        cleanup_ok = cleanup_ok and time.monotonic() < deadline
        if not cleanup_ok:
            CLEANUP_UNCERTAIN = True
        result.update(end=utc(), elapsed_seconds=round(time.monotonic() - start, 3),
                      cleanup_ok=cleanup_ok, cleanup_uncertain=not cleanup_ok,
                      status=('cleanup-uncertain' if not cleanup_ok else
                              'terminal' if child is not None else 'startup-failed'))
        write_new(out / 'terminal.json', result)
        if not cleanup_ok:
            raise CleanupUncertain('command cleanup uncertain')
    need(result.get('exit') != 124, 'command timeout')
    need(result.get('exit') == 0 and result['cleanup_ok'], 'compiler command failed')
    need(all(path.stat().st_size <= log_limit for path in (stdout, stderr)), 'compiler log bound')
    for path in out.iterdir():
        info = path.lstat()
        need(not stat.S_ISLNK(info.st_mode), 'stage artifact type')
        need(not stat.S_ISREG(info.st_mode) or info.st_size <= MAX_FILE, 'stage artifact bound')
    return stdout, stderr


def environment(work):
    return {'PATH': '/usr/bin:/bin', 'HOME': str(work / 'home'), 'TMPDIR': str(work / 'tmp'),
            'LC_ALL': 'C.UTF-8', 'TZ': 'UTC', 'BEND_NO_TELEMETRY': '1',
            'BUN_JSC_forceRAMSize': '2147483648', 'PYTHONDONTWRITEBYTECODE': '1'}


def environment_guard(actual, expected):
    need(set(actual) == set(expected), 'clean environment keys')
    need(actual == expected, 'clean environment values')


def snapshot(root, ignore_git=False):
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        if Path(directory) == root and ignore_git:
            dirs[:] = [name for name in dirs if name != '.git']
        for name in dirs + files:
            path = Path(directory) / name
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                continue
            need(stat.S_ISREG(mode) or stat.S_ISLNK(mode), 'source file type')
            data = os.readlink(path).encode() if stat.S_ISLNK(mode) else read_file(path)
            kind = '120000' if stat.S_ISLNK(mode) else ('100755' if mode & 0o111 else '100644')
            if kind == '120000':
                need(path.resolve(strict=True).is_relative_to(root), 'source symlink escape')
            else:
                need(stat.S_IMODE(mode) == int(kind[-3:], 8), 'source permissions')
            result[path.relative_to(root).as_posix()] = {
                'mode': kind, 'size': len(data), 'sha256': digest(data),
                'blob': hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()}
    return result


def source_guard(root, expected, ignore_git=False):
    need(snapshot(root, ignore_git) == expected, 'source bytes or mode')


def distribution_snapshot(root):
    private_dir(root)

    def unreadable(_error):
        raise Refused('distribution unreadable')

    result = {'.': {'type': 'directory', 'permissions': '0o700'}}
    for directory, dirs, files in os.walk(root, followlinks=False, onerror=unreadable):
        for name in dirs + files:
            path = Path(directory) / name
            info = path.lstat()
            mode = stat.S_IMODE(info.st_mode)
            need(info.st_uid == os.getuid(), 'distribution owner')
            if stat.S_ISDIR(info.st_mode):
                need(not mode & 0o7077, 'distribution permissions')
                record = {'type': 'directory', 'permissions': oct(mode)}
            else:
                need(stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode), 'distribution type')
                if stat.S_ISLNK(info.st_mode):
                    need(path.resolve(strict=True).is_relative_to(root), 'distribution symlink escape')
                    data = os.readlink(path).encode()
                    kind = 'symlink'
                else:
                    need(not mode & 0o7077, 'distribution permissions')
                    data = read_file(path)
                    kind = 'regular'
                record = {'type': kind, 'permissions': oct(mode), 'size': len(data), 'sha256': digest(data)}
            result[path.relative_to(root).as_posix()] = record
    return result


def distribution_guard(root, expected):
    need(distribution_snapshot(root) == expected, 'distribution bytes or mode')


def generated_identity(work, phase):
    need(phase in ('emission', 'publish'), 'generated C phase')
    private_dir(work)
    private_dir(work / phase)
    path = work / phase / 'mime-oracle.c'
    before = path.lstat()
    need(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and
         stat.S_IMODE(before.st_mode) == 0o600 and before.st_nlink == 1, 'generated C direct regular file')
    need(0 < before.st_size <= MAX_FILE, 'generated C bound')
    data = read_file(path)
    after = path.lstat()
    keys = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_nlink', 'st_size', 'st_mtime_ns')
    need(all(getattr(before, key) == getattr(after, key) for key in keys), 'generated C changed')
    return {'path': str(path), 'size': len(data), 'sha256': digest(data),
            'permissions': oct(stat.S_IMODE(after.st_mode)), 'device': after.st_dev, 'inode': after.st_ino}


def publish_generated(work, command):
    checkpoint()
    generated = generated_identity(work, 'emission')
    private_dir(work / 'publish')
    output, destination = work / 'emission/mime-oracle.c', work / 'publish/mime-oracle.c'
    need(not os.path.lexists(destination), 'generated C destination exists')
    os.link(output, destination, follow_symlinks=False)
    output.unlink()
    published = generated_identity(work, 'publish')
    need(all(published[key] == generated[key] for key in ('sha256', 'size', 'permissions', 'device', 'inode')),
         'generated C publication identity')
    write_new(work / 'receipts/emission.json', {'generated_C': generated, 'command': command,
              'artifact_file': 'mime-oracle.c', 'artifact_sha256': published['sha256'],
              'guard_after': 'pass', 'next_gate': 'independent generated-C and lineage review',
              'completion_authority': 'successful adapter process exit and workflow step',
              'compiled': False, 'mail_started': False, 'captures_created': False})


def discard_private_stages(work):
    for name in ('controls', 'install', 'emission'):
        shutil.rmtree(work / name)


def git(root, args, env):
    checkpoint()
    result = subprocess.run(['/usr/bin/git', '-C', str(root), *args], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
                            env={**env, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'})
    need(result.returncode == 0 and not result.stderr and len(result.stdout) <= 1048576, 'git identity')
    return result.stdout


def checkout(root, commit, env):
    need(git(root, ['rev-parse', 'HEAD'], env).decode().strip() == commit, 'checkout commit')
    entries = {}
    for entry in git(root, ['ls-tree', '-rz', 'HEAD'], env).split(b'\0'):
        if entry:
            metadata, path = entry.split(b'\t', 1)
            mode, kind, blob = metadata.decode().split()
            need(kind == 'blob' and mode in ('100644', '100755', '120000'), 'git tree type')
            entries[path.decode()] = {'mode': mode, 'blob': blob}
    found = snapshot(root, True)
    need({name: {k: row[k] for k in ('mode', 'blob')} for name, row in found.items()} == entries,
         'checkout bytes or mode')
    tree = git(root, ['rev-parse', 'HEAD^{tree}'], env).decode().strip()
    return tree, found


def capacity(work):
    """Read only this hosted job's cgroup ancestry. Never change kernel limits."""
    mem = {}
    for line in Path('/proc/meminfo').read_text().splitlines():
        match = re.fullmatch(r'(MemTotal|MemFree):\s+([0-9]+) kB', line)
        if match:
            mem[match[1]] = int(match[2]) * 1024
    need(set(mem) == {'MemTotal', 'MemFree'}, 'memory scope unknown')
    own = Path('/proc/self/cgroup').read_text().strip().splitlines()
    need(len(own) == 1 and own[0].startswith('0::/'), 'memory scope unknown')
    own_path = own[0][3:]
    need('..' not in Path(own_path).parts, 'memory scope unknown')
    mounts = []
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        before, after = line.split(' - ', 1)
        if after.split()[0] == 'cgroup2':
            mounts.append(before.split())
    need(len(mounts) == 1 and mounts[0][3] == '/' and mounts[0][4] == '/sys/fs/cgroup',
         'memory scope unknown')
    root = Path('/sys/fs/cgroup')
    need('memory' in (root / 'cgroup.controllers').read_text().split(), 'memory scope unknown')
    try:
        (root / 'memory.max').lstat()
    except FileNotFoundError:
        pass
    else:
        raise Refused('memory scope unknown')
    current = root / own_path.lstrip('/')
    need(current.is_dir() and current.resolve() == current and current.is_relative_to(root),
         'memory scope unknown')
    headroom = mem['MemFree']
    allocation = mem['MemTotal']
    constraints = []
    while current != root:
        limit_text = (current / 'memory.max').read_text().strip()
        used_text = (current / 'memory.current').read_text().strip()
        need(used_text.isdecimal() and (limit_text == 'max' or limit_text.isdecimal()),
             'memory scope unknown')
        used = int(used_text)
        limit = None if limit_text == 'max' else int(limit_text)
        if limit is not None:
            allocation = min(allocation, limit)
            headroom = min(headroom, max(0, limit - used))
        constraints.append({'cgroup': str(current.relative_to(root)), 'max': limit_text, 'current': used})
        current = current.parent
    # The cgroup-v2 root is not resource-controlled. Missing non-root files refuse above.
    free_disk = shutil.disk_usage(work).free
    result = {'sample_utc': utc(), 'host': mem, 'cgroup_v2_mount_root': '/',
              'own_cgroup': own_path, 'constraints': constraints, 'kernel_root_has_no_memory_max': True,
              'effective_allocation_bytes': allocation, 'effective_free_bytes': headroom,
              'minimum_free_bytes': FLOOR, 'disk_free_bytes': free_disk,
              'minimum_disk_free_bytes': 2 * 1024 ** 3,
              'scope_basis': 'fixed non-container standard public GitHub-hosted VM; visible cgroup-v2 root',
              'heap_heuristic_is_memory_cap': False, 'snapshot_is_reservation': False}
    return result


def closure(stock, bend_home):
    pending, result = [stock / 'tests/mime-oracle.bend'], {}
    while pending:
        path = pending.pop().resolve(strict=True)
        name = ('stock/' + path.relative_to(stock).as_posix() if path.is_relative_to(stock)
                else 'bend/' + path.relative_to(bend_home).as_posix())
        if name in result:
            continue
        data = read_file(path)
        result[name] = {'sha256': digest(data), 'size': len(data)}
        for line in data.decode().splitlines():
            if not line.startswith('import '):
                continue
            match = re.fullmatch(r'import (Base|\.{1,2}/[A-Za-z0-9_./-]+\.bend)(?: as [A-Za-z0-9_]+)?', line)
            need(match is not None, 'unknown source import')
            target = bend_home / 'bend2/base.bend' if match[1] == 'Base' else path.parent / match[1]
            resolved = target.resolve(strict=True)
            need(resolved.is_relative_to(stock) or resolved == bend_home / 'bend2/base.bend',
                 'source import escape')
            pending.append(resolved)
    need('stock/tests/composition-cases.bend' in result and 'stock/src/tools.bend' in result,
         'oracle registry missing')
    return result


def bounded(argv, seconds):
    return ['/usr/bin/timeout', '--signal=TERM', '--kill-after=30s', str(seconds) + 's', *argv]


def main():
    global CLEANUP_UNCERTAIN
    need(len(sys.argv) == 1, 'no command selection')
    need(platform.system() == 'Linux' and platform.machine() == 'x86_64' and
         sys.version_info[:3] == (3, 13, 18), 'host runtime')
    need(os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted' and
         os.environ.get('GITHUB_REPOSITORY') == 'albertc71/MailBend' and
         os.environ.get('GITHUB_REF') == BRANCH and os.environ.get('GITHUB_EVENT_NAME') == 'push',
         'hosted event')
    head = os.environ.get('GITHUB_SHA', '')
    need(re.fullmatch('[0-9a-f]{40}', head) is not None, 'candidate identity')
    candidate = Path(__file__).resolve().parents[1]
    stock = candidate.parent / 'stock'
    work = Path(os.environ['RUNNER_TEMP']).resolve() / 'mime-observation-124'
    need(not os.path.lexists(work), 'existing or uncertain attempt')
    work.mkdir(mode=0o700)
    for name in ('home', 'tmp', 'receipts', 'controls', 'install', 'emission', 'publish'):
        (work / name).mkdir(mode=0o700)
    env = environment(work)
    environment_guard(env, environment(work))
    receipts, commands, outcome = work / 'receipts', [], 'failed'
    failure_category, postguard = None, 'not reached'
    stock_files = candidate_files = distribution = tools = None
    try:
        stock_tree, stock_files = checkout(stock, BASE, env)
        need(stock_tree == BASE_TREE and len(stock_files) == 478, 'stock source identity')
        candidate_tree, candidate_files = checkout(candidate, head, env)
        need(set(candidate_files) == set(stock_files) | ADDITIONS and not (set(stock_files) & ADDITIONS),
             'candidate file scope')
        need(all(candidate_files[name] == record for name, record in stock_files.items()),
             'candidate inherited source')
        parent = git(candidate, ['rev-list', '--parents', '-n', '1', 'HEAD'], env).decode().split()
        need(parent == [head, BASE], 'candidate parent')
        for path, pin in (('tests/mime-observation-controls.py', CONTROL_SHA),
                          ('tests/test-mime-observation.py', DRIVER_SHA),
                          ('tests/mime-observation.bend', TEMPLATE_SHA)):
            need(candidate_files[path]['sha256'] == pin, 'proposal source identity')
        tools = {name: identity('/usr/bin/' + name) for name in
                 ('git', 'timeout', 'sh', 'curl', 'tar', 'uname', 'mktemp', 'sha256sum', 'mkdir', 'rm', 'mv')}
        tools['python'] = identity(sys.executable)
        write_new(receipts / 'source.json', {'stock_commit': BASE, 'stock_tree': BASE_TREE,
                  'candidate_commit': head, 'candidate_tree': candidate_tree,
                  'stock_files': stock_files, 'candidate_files': candidate_files,
                  'host_tools': tools, 'job': os.environ.get('GITHUB_JOB'),
                  'platform': {'system': platform.system(), 'machine': platform.machine(),
                               'kernel': platform.release(), 'python': list(sys.version_info[:3])},
                  'run_id': os.environ.get('GITHUB_RUN_ID'), 'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT')})
        need(os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'no rerun')
        controls = candidate / 'tests/mime-observation-controls.py'
        try:
            supervise(bounded([sys.executable, '-I', '-B', str(controls)], 180),
                      work / 'controls', work / 'controls', env, 180, commands, log_limit=65536)
        except BaseException:
            # A failed fixture may have had owned participants outside the batch leader's group.
            CLEANUP_UNCERTAIN = True
            raise
        control_result = json.loads(read_file(work / 'controls/result.json', 65536))
        need(control_result['status'] == 'pass', 'controls failed')
        write_new(receipts / 'controls.json', control_result)
        checkpoint()
        source_guard(stock, stock_files, True)
        source_guard(candidate, candidate_files, True)
        supervise(bounded(['/usr/bin/sh', str(stock / 'scripts/install-bend.sh')], 180),
                  work / 'install', stock, env, 180, commands)
        compiler = work / 'home/.bend/bin/bend'
        need(identity(compiler)['sha256'] == BEND_SHA, 'Bend executable identity')
        distribution = distribution_snapshot(work / 'home/.bend')
        graph = closure(stock, work / 'home/.bend')
        try:
            resource_receipt = capacity(work)
        except (OSError, ValueError):
            raise Refused('memory scope unknown') from None
        write_new(receipts / 'resources.json', resource_receipt)
        need(resource_receipt['effective_free_bytes'] >= FLOOR and
             resource_receipt['effective_allocation_bytes'] >= FLOOR, 'memory admission floor')
        need(resource_receipt['disk_free_bytes'] >= resource_receipt['minimum_disk_free_bytes'],
             'disk admission floor')
        compiler_record = identity(compiler)
        output = work / 'emission/mime-oracle.c'
        command = bounded([str(compiler), str(stock / 'tests/mime-oracle.bend'), '-o', str(output)], 1200)
        write_new(receipts / 'inputs.json', {'compiler': compiler_record,
                  'release': '2.0.35', 'archive_sha256_checked_by_pristine_installer': ARCHIVE_SHA,
                  'distribution_files': distribution, 'static_bend_import_closure': graph,
                  'foreign_identity_scope': 'all distribution files, not compiler-selected foreign closure',
                  'environment_keys': sorted(env),
                  'environment_sha256': digest(json.dumps(env, sort_keys=True).encode()),
                  'BUN_JSC_forceRAMSize': '2147483648', 'heap_heuristic_is_memory_cap': False,
                  'argv': command, 'guard_before': 'pass',
                  'generated_executables_allowed': False})
        source_guard(stock, stock_files, True)
        source_guard(candidate, candidate_files, True)
        distribution_guard(work / 'home/.bend', distribution)
        need(all(identity(record['path']) == record for record in tools.values()), 'host tool drift')
        supervise(command, work / 'emission', stock, env, 1200, commands)
        arm_finalization()
        need(identity(compiler) == compiler_record, 'compiler drift')
        source_guard(stock, stock_files, True)
        source_guard(candidate, candidate_files, True)
        distribution_guard(work / 'home/.bend', distribution)
        need(all(identity(record['path']) == record for record in tools.values()), 'host tool drift')
        publish_generated(work, commands[-1])
        outcome = 'emitted-awaiting-review'
    except Refused as error:
        failure_category = str(error)
        raise
    except BaseException:
        failure_category = 'cancelled' if CANCELLED else 'unexpected failure'
        raise
    finally:
        if not CLEANUP_UNCERTAIN and stock_files is not None and candidate_files is not None:
            try:
                source_guard(stock, stock_files, True)
                source_guard(candidate, candidate_files, True)
                if distribution is not None:
                    distribution_guard(work / 'home/.bend', distribution)
                if tools is not None:
                    need(all(identity(record['path']) == record for record in tools.values()), 'host tool drift')
                postguard = 'pass'
            except BaseException:
                postguard = 'failed'
                outcome = 'failed'
                failure_category = 'postguard failed'
        elif CLEANUP_UNCERTAIN:
            postguard = 'not run after cleanup uncertainty'
        if CANCELLED:
            outcome, failure_category = 'failed', 'cancelled'
        status = {'outcome': outcome,
                  'completion_authority': 'successful adapter process exit and workflow step',
                  'cleanup_uncertain': CLEANUP_UNCERTAIN,
                  'category': failure_category, 'postguard': postguard,
                  'cancelled': bool(CANCELLED), 'automatic_retry': False,
                  'compiler_count': sum('mime-oracle.bend' in str(row['argv']) for row in commands),
                  'commands': [{k: row.get(k) for k in ('status', 'exit', 'start', 'end',
                               'elapsed_seconds', 'leader_reaped', 'group_completion',
                               'cleanup_ok', 'cleanup_uncertain')} for row in commands]}
        write_new(receipts / 'status.json', status)
        if not CLEANUP_UNCERTAIN:
            discard_private_stages(work)
    checkpoint()
    need(outcome == 'emitted-awaiting-review', 'emission incomplete')


if __name__ == '__main__':
    os.umask(0o077)
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, changed_signal)
    try:
        main()
    except BaseException:
        print('MIME-124 STOP: failed, cancelled, or cleanup uncertain', file=sys.stderr)
        raise SystemExit(1) from None
    print('MIME-124 C emitted; independent review required before compilation')
