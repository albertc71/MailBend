#!/usr/bin/env python3
"""Benign controls for the active hosted emission supervisor, never mail code."""
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import shutil
import stat
import subprocess
import sys
import time
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
CASES = ('source-refusal', 'environment-refusal', 'distribution-modes', 'generated-file',
         'atomic-handshake', 'normal', 'startup-missing', 'nonzero',
         'timeout', 'stdout-overflow', 'stderr-overflow', 'artifact-overflow',
         'sigint', 'sigterm', 'sighup', 'late-link', 'late-receipt', 'late-cleanup',
         'same-group', 'absolute-budget', 'restored-normal')
LEAVES = ('normal', 'nonzero', 'sleep', 'stdout', 'stderr', 'artifact', 'same-group',
          'late-link', 'late-receipt', 'late-cleanup')


def check(ok, category):
    if not ok:
        raise RuntimeError(category)


def save(path, value):
    pending = path.with_name(path.name + '.pending')
    fd = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write('\n')
        os.link(pending, path, follow_symlinks=False)
    finally:
        pending.unlink()


def wait_file(path):
    end = time.monotonic() + 5
    while not path.exists():
        check(time.monotonic() < end, 'handshake deadline')
        time.sleep(0.02)
    check(stat.S_ISREG(path.lstat().st_mode) and path.stat().st_size <= 4096, 'handshake file')
    return json.loads(path.read_bytes())


def late_leaf(kind, work):
    run = load_adapter()
    for name in ('emission', 'publish', 'receipts', 'controls', 'install'):
        (work / name).mkdir(mode=0o700)
    (work / 'emission/mime-oracle.c').write_bytes(b'fixed')
    number = {'late-link': signal.SIGINT, 'late-receipt': signal.SIGTERM,
              'late-cleanup': signal.SIGHUP}[kind]
    original_link, original_write, original_rmtree = os.link, run.write_new, shutil.rmtree

    def linked(*args, **kwargs):
        original_link(*args, **kwargs)
        os.kill(os.getpid(), number)

    def written(*args, **kwargs):
        original_write(*args, **kwargs)
        os.kill(os.getpid(), number)

    def removed(*args, **kwargs):
        original_rmtree(*args, **kwargs)
        os.kill(os.getpid(), number)

    run.arm_finalization()
    try:
        with patch.object(os, 'link', linked if kind == 'late-link' else original_link), \
             patch.object(run, 'write_new', written if kind == 'late-receipt' else original_write), \
             patch.object(shutil, 'rmtree', removed if kind == 'late-cleanup' else original_rmtree):
            run.publish_generated(work, {'synthetic': True})
            run.discard_private_stages(work)
            save(work / 'incorrect-success.json', {'continued': True})
    except SystemExit as error:
        check(error.code == 1 and run.CANCELLED == number, 'late cancellation result')
        save(work / 'cancelled.json', {'signal': int(number), 'exit': 1})
        raise
    return 0


def leaf(kind):
    check(kind in LEAVES, 'leaf selection')
    work = Path.cwd()
    wait_file(work / 'launch.json')
    if kind in ('late-link', 'late-receipt', 'late-cleanup'):
        return late_leaf(kind, work)
    if kind == 'normal':
        os.write(1, b'synthetic-normal\n')
    elif kind == 'nonzero':
        os.write(2, b'synthetic-nonzero\n')
        return 7
    elif kind == 'sleep':
        time.sleep(60)
        return 9
    elif kind in ('stdout', 'stderr'):
        os.write(1 if kind == 'stdout' else 2, b'x' * 8192)
        time.sleep(60)
    elif kind == 'artifact':
        (work / 'oversized').write_bytes(b'x' * 8192)
        time.sleep(60)
    else:
        keeper = os.fork()
        if keeper == 0:
            child = os.fork()
            if child == 0:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                save(work / 'leaf-ready.json', {'pid': os.getpid()})
                time.sleep(60)
                os._exit(9)
            os.setsid()
            save(work / 'keeper-ready.json', {'keeper': os.getpid(), 'leaf': child})
            end = time.monotonic() + 20
            while not (work / 'reap.json').exists() and time.monotonic() < end:
                time.sleep(0.02)
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
            found, status = os.waitpid(child, 0)
            save(work / 'keeper-reaped.json', {'leaf': found, 'status': status})
            os._exit(0)
        save(work / 'leader-ready.json', {'leader': os.getpid(), 'keeper': keeper})
        wait_file(work / 'go.json')
    return 0


def load_adapter():
    spec = importlib.util.spec_from_file_location('emission_control_target', HERE / 'mime-observation-hosted.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def refusal(call, exception, category):
    try:
        call()
    except exception as error:
        check(str(error) == category, 'wrong failure category')
    else:
        raise RuntimeError('missing intended failure')


def ready(fd):
    return bool(select.select([fd], [], [], 0)[0])


def close_owned(owned, launches, work):
    failures = []
    if any(row['role'] == 'custodian' for row in owned) and not (work / 'reap.json').exists():
        try:
            save(work / 'reap.json', {'reap': True})
        except Exception:
            failures.append('custodian release')
    for row in owned:
        try:
            if row['role'] != 'custodian' and not ready(row['fd']):
                signal.pidfd_send_signal(row['fd'], signal.SIGKILL)
        except OSError as error:
            if error.errno != errno.ESRCH:
                failures.append('owned signal')
    end = time.monotonic() + 6
    for row in owned:
        try:
            while not ready(row['fd']) and time.monotonic() < end:
                time.sleep(0.02)
            if not ready(row['fd']):
                failures.append('owned termination uncertain')
                signal.pidfd_send_signal(row['fd'], signal.SIGKILL)
        except OSError:
            failures.append('owned termination probe')
    for proc in launches:
        try:
            if proc.returncode is None:
                proc.kill()
                proc.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            failures.append('direct child reap')
    for row in owned:
        try:
            os.close(row['fd'])
        except OSError:
            failures.append('pidfd close')
    check(not failures, 'control cleanup uncertain')


def case(name, root):
    run = load_adapter()
    work = root / name
    work.mkdir(mode=0o700)
    commands, owned, launches, group_calls = [], [], [], []
    environment = dict(os.environ)
    before_fds = set(os.listdir('/proc/self/fd'))
    original_popen, original_killpg = subprocess.Popen, os.killpg
    handlers = {}
    caught = False

    def tracked(argv, *args, **kwargs):
        leaf_argv = argv
        if name == 'timeout':
            check(argv[:4] == ['/usr/bin/timeout', '--signal=TERM', '--kill-after=30s', '0.25s'],
                  'fixed timeout wrapper')
            leaf_argv = argv[4:]
        check(leaf_argv[:4] == [sys.executable, '-I', '-B', str(Path(__file__).resolve())] and
              len(leaf_argv) == 6 and leaf_argv[4] == '--leaf' and leaf_argv[5] in LEAVES,
              'only fixed Python leaves')
        check(not args and kwargs['start_new_session'] is True and kwargs['env'] == environment and
              kwargs['cwd'] == work, 'fixed leaf launch boundary')
        proc = original_popen(argv, *args, **kwargs)
        launches.append(proc)
        owned.append({'role': 'leader', 'fd': os.pidfd_open(proc.pid), 'pid': proc.pid})
        check(os.getpgid(proc.pid) == proc.pid, 'leader group ownership')
        save(work / 'launch.json', {'launch': True})
        if leaf_argv[5] == 'same-group':
            leader = wait_file(work / 'leader-ready.json')
            keeper = wait_file(work / 'keeper-ready.json')
            child = wait_file(work / 'leaf-ready.json')
            check(leader == {'leader': proc.pid, 'keeper': keeper['keeper']} and
                  keeper['leaf'] == child['pid'], 'descendant provenance')
            for pid, role, pgid in ((keeper['keeper'], 'custodian', keeper['keeper']),
                                    (keeper['leaf'], 'leaf', proc.pid)):
                fd = os.pidfd_open(pid)
                owned.append({'role': role, 'fd': fd, 'pid': pid})
                check(os.getpgid(pid) == pgid, 'descendant group ownership')
            save(work / 'go.json', {'go': True})
        if name in ('sigint', 'sigterm', 'sighup'):
            os.kill(os.getpid(), {'sigint': signal.SIGINT, 'sigterm': signal.SIGTERM,
                                 'sighup': signal.SIGHUP}[name])
        return proc

    def checked_group(pgid, number):
        proc = next((p for p in launches if p.pid == pgid), None)
        check(proc is not None, 'group is not owned')
        check((number in (signal.SIGTERM, signal.SIGKILL) and proc.returncode is None) or
              (number == 0 and proc.returncode is not None), 'signal ordering')
        group_calls.append(int(number))
        return original_killpg(pgid, number)

    try:
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            handlers[number] = signal.signal(number, run.changed_signal)
        if name == 'source-refusal':
            target = work / 'source'
            target.mkdir(mode=0o700)
            (target / 'input').write_bytes(b'fixed')
            (target / 'input').chmod(0o644)
            expected = {'input': {'mode': '100644', 'size': 5,
                        'sha256': '992a93455c71fedd36ac9bbc439952c041cf61445958472af479269b8d873513',
                        'blob': 'f6499606c0122255a3d438bacdce5bbb974c063c'}}
            run.source_guard(target, expected)
            (target / 'input').write_bytes(b'wrong')
            refusal(lambda: run.source_guard(target, expected), run.Refused, 'source bytes or mode')
            (target / 'input').write_bytes(b'fixed')
            run.source_guard(target, expected)
            return {'case': name, 'status': 'pass', 'category': 'source bytes or mode'}
        if name == 'environment-refusal':
            expected = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C.UTF-8'}
            run.environment_guard(expected, expected)
            refusal(lambda: run.environment_guard({**expected, 'HTTP_PROXY': 'synthetic'}, expected),
                    run.Refused, 'clean environment keys')
            refusal(lambda: run.environment_guard({**expected, 'PATH': '/synthetic'}, expected),
                    run.Refused, 'clean environment values')
            return {'case': name, 'status': 'pass', 'category': 'clean environment keys and values'}
        if name == 'atomic-handshake':
            path = work / 'literal.json'
            original_link = os.link
            seen = []

            def complete_before_publish(source, destination, **kwargs):
                check(source.read_bytes() == b'{"ready": true}\n' and not destination.exists(),
                      'complete unpublished handshake')
                seen.append(True)
                return original_link(source, destination, **kwargs)

            with patch.object(os, 'link', complete_before_publish):
                save(path, {'ready': True})
            check(seen == [True] and wait_file(path) == {'ready': True}, 'atomic handshake result')
            try:
                save(path, {'ready': False})
            except FileExistsError:
                pass
            else:
                raise RuntimeError('handshake clobbered')
            check(path.read_bytes() == b'{"ready": true}\n' and not path.with_name('literal.json.pending').exists(),
                  'handshake no clobber')
            return {'case': name, 'status': 'pass', 'category': 'complete atomic no-clobber handshake'}
        if name == 'distribution-modes':
            target = work / 'distribution'
            target.mkdir(mode=0o700)
            for filename, mode in (('data', 0o600), ('executable', 0o700)):
                (target / filename).write_bytes(b'fixed')
                (target / filename).chmod(mode)
            literal = {'type': 'regular', 'size': 5,
                       'sha256': '992a93455c71fedd36ac9bbc439952c041cf61445958472af479269b8d873513'}
            expected = {'.': {'type': 'directory', 'permissions': '0o700'},
                        'data': {**literal, 'permissions': '0o600'},
                        'executable': {**literal, 'permissions': '0o700'}}
            run.distribution_guard(target, expected)
            refusal(lambda: run.snapshot(target), run.Refused, 'source permissions')
            (target / 'data').write_bytes(b'wrong')
            refusal(lambda: run.distribution_guard(target, expected), run.Refused, 'distribution bytes or mode')
            (target / 'data').write_bytes(b'fixed')
            (target / 'executable').chmod(0o600)
            refusal(lambda: run.distribution_guard(target, expected), run.Refused, 'distribution bytes or mode')
            (target / 'executable').chmod(0o700)
            run.distribution_guard(target, expected)
            return {'case': name, 'status': 'pass', 'category': 'private modes retained, drift refused'}
        if name == 'generated-file':
            for phase in ('emission', 'publish', 'receipts'):
                (work / phase).mkdir(mode=0o700)
            output = work / 'emission/mime-oracle.c'
            output.write_bytes(b'fixed')
            record = run.generated_identity(work, 'emission')
            check(record['size'] == 5 and record['permissions'] == '0o600' and record['sha256'] ==
                  '992a93455c71fedd36ac9bbc439952c041cf61445958472af479269b8d873513', 'literal generated identity')
            target = work / 'literal'
            output.rename(target)
            output.symlink_to(target)
            refusal(lambda: run.generated_identity(work, 'emission'), run.Refused, 'generated C direct regular file')
            output.unlink()
            target.rename(output)
            published = work / 'publish/mime-oracle.c'
            published.symlink_to(output)
            refusal(lambda: run.generated_identity(work, 'publish'), run.Refused, 'generated C direct regular file')
            refusal(lambda: run.publish_generated(work, {'synthetic': True}), run.Refused, 'generated C destination exists')
            published.unlink()
            run.publish_generated(work, {'synthetic': True})
            check(not output.exists() and published.read_bytes() == b'fixed' and not published.is_symlink(),
                  'direct generated publication')
            return {'case': name, 'status': 'pass', 'category': 'direct C only, links and clobber refused'}
        kind = {'normal': 'normal', 'restored-normal': 'normal', 'nonzero': 'nonzero', 'stdout-overflow': 'stdout',
                'stderr-overflow': 'stderr', 'artifact-overflow': 'artifact',
                'same-group': 'same-group', 'late-link': 'late-link',
                'late-receipt': 'late-receipt', 'late-cleanup': 'late-cleanup'}.get(name, 'sleep')
        argv = [sys.executable, '-I', '-B', str(Path(__file__).resolve()), '--leaf', kind]
        seconds = 0.25
        category = {'nonzero': 'compiler command failed', 'timeout': 'command timeout',
                    'stdout-overflow': 'compiler log bound', 'stderr-overflow': 'compiler log bound',
                    'artifact-overflow': 'stage artifact bound', 'sigint': 'cancelled',
                    'sigterm': 'cancelled', 'sighup': 'cancelled',
                    'same-group': 'command cleanup uncertain',
                    'absolute-budget': 'command cleanup uncertain',
                    'startup-missing': 'command startup failed', 'late-link': 'compiler command failed',
                    'late-receipt': 'compiler command failed', 'late-cleanup': 'compiler command failed'}.get(name)
        if name in ('stdout-overflow', 'stderr-overflow'):
            run.MAX_LOG = 4096
        if name == 'artifact-overflow':
            run.MAX_FILE = 4096
        if name == 'timeout':
            argv = run.bounded(argv, seconds)
        if name == 'startup-missing':
            argv = [str(work / 'fixed-nonexistent-executable')]
            check(not Path(argv[0]).exists(), 'missing target exists')
        with patch.object(subprocess, 'Popen', original_popen if name == 'startup-missing' else tracked), \
             patch.object(os, 'killpg', checked_group):
            call = lambda: run.supervise(argv, work, work, environment, seconds, commands)
            if name in ('normal', 'restored-normal'):
                out, err = call()
                check(out.read_bytes() == b'synthetic-normal\n' and err.read_bytes() == b'',
                      'normal output')
            else:
                refusal(call, run.CleanupUncertain if name in ('same-group', 'absolute-budget')
                        else run.Refused, category)
                caught = True
            if name in ('same-group', 'absolute-budget'):
                check(run.CLEANUP_UNCERTAIN and commands[-1]['status'] == 'cleanup-uncertain',
                      'sticky uncertainty')
                before = len(launches)
                refusal(call, run.CleanupUncertain, 'prior cleanup uncertain')
                check(len(launches) == before, 'follow-on launch blocked')
            elif name != 'startup-missing':
                check(commands[-1]['cleanup_ok'] and not run.CLEANUP_UNCERTAIN and
                      commands[-1]['group_completion'] == 'absent-ESRCH', 'group cleanup')
            if name == 'nonzero':
                check(commands[-1]['exit'] == 7 and (work / 'stderr').read_bytes() == b'synthetic-nonzero\n',
                      'nonzero exit')
            if name in ('late-link', 'late-receipt', 'late-cleanup'):
                number = {'late-link': signal.SIGINT, 'late-receipt': signal.SIGTERM,
                          'late-cleanup': signal.SIGHUP}[name]
                check(commands[-1]['exit'] == 1 and wait_file(work / 'cancelled.json') ==
                      {'signal': int(number), 'exit': 1} and not (work / 'incorrect-success.json').exists(),
                      'late cancellation is terminal')
                check((work / 'receipts/emission.json').exists() == (name != 'late-link'),
                      'late receipt boundary')
                check((work / 'stdout').read_bytes() == b'' and (work / 'stderr').read_bytes() == b'',
                      'late cancellation diagnostics')
            if name == 'same-group':
                check(commands[-1]['group_completion'] == 'surviving-group-at-deadline',
                      'held zombie category')
                save(work / 'reap.json', {'reap': True})
                status = wait_file(work / 'keeper-reaped.json')
                child = next(row for row in owned if row['role'] == 'leaf')
                check(status['leaf'] == child['pid'] and os.WIFSIGNALED(status['status']) and
                      os.WTERMSIG(status['status']) == signal.SIGKILL, 'custodian reaped leaf')
        if name not in ('startup-missing',):
            check(group_calls[:2] == [int(signal.SIGTERM), int(signal.SIGKILL)], 'TERM then KILL')
            check(set(group_calls[2:]) <= {0}, 'no destructive post-reap signal')
        return {'case': name, 'status': 'pass', 'category': category or 'normal completion',
                'intended_failure_seen': caught, 'launches': len(launches),
                'cleanup_uncertainty_blocked_follow_on': run.CLEANUP_UNCERTAIN,
                'final_orphan_reaping_claimed': False}
    finally:
        try:
            close_owned(owned, launches, work)
        finally:
            for number, handler in handlers.items():
                signal.signal(number, handler)
        check(set(os.listdir('/proc/self/fd')) == before_fds, 'descriptor cleanup')


def main():
    check(len(sys.argv) == 1, 'no control selection')
    check(hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal'), 'pidfd APIs')
    root = Path.cwd()
    check(root.is_absolute() and root.name == 'controls' and
          stat.S_IMODE(root.stat().st_mode) == 0o700, 'private controls directory')
    sources = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in
               (Path(__file__).resolve(), HERE / 'mime-observation-hosted.py')}
    results = []
    for name in CASES:
        results.append(case(name, root))
    check(all(hashlib.sha256(path.read_bytes()).hexdigest() == pin for path, pin in sources.items()),
          'control source drift')
    save(root / 'result.json', {'status': 'pass', 'cases': results,
         'omitted_retained_controls': ['compiler dependency/link parsers and release packet checks are not active',
             'runtime-driver pipes, signals and descendants are not imported in this emission-only job',
             'batch cancellation and ESRCH race injection remain untested',
             'observation arming and capture cleanup remain behind the later ready-manifest gate'],
         'compiler_or_mail_execution': False})


if __name__ == '__main__':
    os.umask(0o077)
    try:
        if len(sys.argv) == 3 and sys.argv[1] == '--leaf':
            raise SystemExit(leaf(sys.argv[2]))
        main()
    except Exception:
        print('MIME-124 CONTROLS FAILED OR UNCERTAIN', file=sys.stderr)
        raise SystemExit(1) from None
