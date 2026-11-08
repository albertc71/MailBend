"""Hosted-only sampled session RSS supervision, not a hard allocation limit."""
from dataclasses import dataclass
import base64
import json
import math
import os
from pathlib import Path
import re
import select
import selectors
import signal
import subprocess
import sys
import time


@dataclass(frozen=True)
class Limits:
    rss_kib: int = 3145728
    seconds: float = 840
    cleanup_seconds: float = 5
    output_bytes: int = 67108864
    interval: float = .01


def redacted(raw, secrets):
    for secret in sorted(set(secrets), key=len, reverse=True):
        if secret:
            value = secret.encode()
            raw = raw.replace(value, b"<redacted>")
            raw = raw.replace(base64.b64encode(value), b"<redacted>")
    return raw.decode("utf-8", "replace")


def stat(pid):
    with open(f"/proc/{pid}/stat", "rb") as source:
        raw = source.read(8193)
    if len(raw) > 8192 or int(raw.split(b" ", 1)[0]) != pid:
        raise ValueError("process observation")
    fields = raw.rsplit(b")", 1)[1].split()
    state, session, started, pages = fields[0], int(fields[3]), int(fields[19]), int(fields[21])
    if pages < 0 or started < 0:
        raise ValueError("process observation")
    return session, started, pages, state


def exited(fd):
    poll = select.poll()
    poll.register(fd, select.POLLIN)
    events = poll.poll(0)
    if any(flags & select.POLLNVAL for _, flags in events):
        raise ValueError("invalid pidfd")
    return bool(events)


def before(deadline):
    if time.monotonic() >= deadline:
        raise TimeoutError("supervision deadline")


class Session:
    def __init__(self, process):
        self.pid = process.pid
        self.members = {}

    def admit_leader(self):
        fd = os.pidfd_open(self.pid)
        # Direct-child ownership does not depend on readable proc metadata.
        self.members[self.pid] = (None, fd)
        identity = stat(self.pid)
        if identity[0] != self.pid:
            raise ValueError("session identity")
        self.members[self.pid] = (identity[1], fd)

    def observe(self, pid, deadline):
        observed = stat(pid)
        if observed[0] != self.pid:
            return None
        prior = self.members.get(pid)
        if prior is not None and prior[0] is None and pid == self.pid:
            self.members[pid] = (observed[1], prior[1])
        elif prior is not None and prior[0] != observed[1]:
            if not exited(prior[1]):
                raise ValueError("live process identity changed")
            os.close(prior[1])
            del self.members[pid]
            prior = None
        if prior is None:
            if len(self.members) >= 4096:
                raise ValueError("session member limit")
            before(deadline)
            fd = os.pidfd_open(pid)
            try:
                confirmed = stat(pid)
                if confirmed[:2] != observed[:2]:
                    raise ValueError("process identity changed during admission")
                self.members[pid] = (confirmed[1], fd)
                observed = confirmed
            except BaseException:
                os.close(fd)
                raise
        return observed

    def sample(self, deadline, *, cleanup=False):
        live = set()
        total = 0
        observed_all = True
        page_kib = os.sysconf("SC_PAGE_SIZE") // 1024
        for pid, (_, fd) in tuple(self.members.items()):
            before(deadline)
            try:
                if pid != self.pid and exited(fd):
                    os.close(fd)
                    del self.members[pid]
            except (OSError, ValueError):
                if not cleanup:
                    raise
                observed_all = False
        with os.scandir("/proc") as entries:
            for count, entry in enumerate(entries):
                before(deadline)
                if count >= 65536:
                    raise ValueError("process inventory limit")
                if not entry.name.isdecimal():
                    continue
                pid = int(entry.name)
                try:
                    observed = self.observe(pid, deadline)
                except (FileNotFoundError, ProcessLookupError):
                    continue
                except (OSError, ValueError, IndexError):
                    if not cleanup:
                        raise
                    observed_all = False
                    continue
                if observed is not None and observed[3] not in (b"Z", b"X"):
                    live.add(pid)
                    total += observed[2] * page_kib
        for pid, (_, fd) in tuple(self.members.items()):
            before(deadline)
            try:
                if pid not in live and not exited(fd):
                    raise ValueError("known live member was not observed")
            except (OSError, ValueError):
                if not cleanup:
                    raise
                observed_all = False
                live.add(pid)
        return total, live, observed_all

    def kill(self, deadline):
        failed = False
        residual = False
        if self.pid not in self.members:
            before(deadline)
            try:
                # Only the direct, unreaped child may use this numeric fallback.
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError:
                failed = True
        for pid, (_, fd) in self.members.items():
            before(deadline)
            try:
                residual |= pid != self.pid and not exited(fd)
                signal.pidfd_send_signal(fd, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except (OSError, ValueError):
                failed = True
        return not failed, residual

    def close(self):
        complete = True
        for _, fd in self.members.values():
            try:
                os.close(fd)
            except OSError:
                complete = False
        self.members.clear()
        return complete


def supervise(command, limits=Limits(), *, secrets=()):
    """Run one reviewed session; descendants that call setsid are unsupported."""
    if (sys.platform != "linux" or not all(hasattr(os, name) for name in
            ("waitid", "WNOWAIT", "pidfd_open")) or not hasattr(signal, "pidfd_send_signal")):
        raise ValueError("Linux waitid and pidfds are required")
    if not (type(limits.rss_kib) is int and type(limits.output_bytes) is int
            and all(type(v) in (int, float) and math.isfinite(v)
                    for v in (limits.seconds, limits.cleanup_seconds, limits.interval))
            and 0 < limits.rss_kib <= 3145728 and 0 < limits.seconds <= 840
            and 0 < limits.cleanup_seconds <= 5 and 0 < limits.output_bytes <= 67108864
            and 0 < limits.interval <= .01):
        raise ValueError("invalid supervision limits")
    started = time.monotonic()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    counts = {name: 0 for name in buffers}
    eof = set()
    later_failures = set()
    peak = samples = 0
    cancelled = 0
    process = session = None
    reason = "observation"
    cleanup_complete = False
    residual_cleanup = False
    exit_code = None
    selector = selectors.DefaultSelector()
    previous = {}

    def cancel(number, _frame):
        nonlocal cancelled
        if not cancelled:
            cancelled = number

    def drain():
        overflow = False
        for key, _ in selector.select(0):
            chunk = os.read(key.fd, 65536)
            name = key.data
            if not chunk:
                eof.add(name)
                selector.unregister(key.fileobj)
                key.fileobj.close()
                continue
            counts[name] += len(chunk)
            remaining = limits.output_bytes - len(buffers[name])
            buffers[name].extend(chunk[:remaining])
            overflow |= counts[name] > limits.output_bytes
        return overflow

    try:
        previous[signal.SIGCHLD] = signal.signal(signal.SIGCHLD, signal.SIG_DFL)
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.signal(number, cancel)
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        session = Session(process)
        for name in buffers:
            stream = getattr(process, name)
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        session.admit_leader()
        payload_deadline = started + limits.seconds
        while True:
            rss, live, _ = session.sample(payload_deadline)
            peak = max(peak, rss)
            samples += 1
            overflow = drain()
            ended = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if cancelled:
                reason = "cancelled"
            elif rss > limits.rss_kib:
                reason = "rss_limit"
            elif time.monotonic() - started >= limits.seconds:
                reason = "deadline"
            elif overflow:
                reason = "output_limit"
            elif ended is not None:
                reason = ("residual_children" if live - {process.pid} else
                          "completed" if ended.si_code == os.CLD_EXITED and ended.si_status == 0 else "exit")
            else:
                time.sleep(limits.interval)
                continue
            break
    except TimeoutError:
        reason = "cancelled" if cancelled else "deadline"
    except (OSError, ValueError, IndexError):
        reason = "observation"
    finally:
        deadline = time.monotonic() + limits.cleanup_seconds
        observation_ok = True
        if session is not None:
            while time.monotonic() < deadline:
                try:
                    signaled, residual = session.kill(deadline)
                    residual_cleanup |= residual
                    if reason == "completed" and residual:
                        reason = "residual_children"
                    if not signaled:
                        later_failures.add("signal")
                    _, live, observed = session.sample(deadline, cleanup=True)
                    residual_cleanup |= bool(live - {process.pid})
                    if not observed:
                        observation_ok = False
                        later_failures.add("observation")
                    if reason == "completed" and live - {process.pid}:
                        reason = "residual_children"
                except (OSError, ValueError, IndexError):
                    observation_ok = False
                    later_failures.add("observation")
                    live = None
                try:
                    before(deadline)
                    signaled, residual = session.kill(deadline)
                    residual_cleanup |= residual
                    if reason == "completed" and residual:
                        reason = "residual_children"
                    if not signaled:
                        later_failures.add("signal")
                    if drain():
                        if reason == "completed":
                            reason = "output_limit"
                        else:
                            later_failures.add("output_limit")
                    ended = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                    if live == set() and ended is not None and not selector.get_map():
                        cleanup_complete = observation_ok
                        break
                except (OSError, ValueError):
                    observation_ok = False
                    later_failures.add("cleanup")
                time.sleep(min(limits.interval, max(0, deadline - time.monotonic())))
            if not session.close():
                observation_ok = False
                cleanup_complete = False
                later_failures.add("close")
        elif process is not None:
            # The unreaped direct child cannot have its PID recycled.
            try:
                os.kill(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if process is not None:
            try:
                process.wait(timeout=max(0, deadline - time.monotonic()))
                exit_code = process.returncode
            except (subprocess.TimeoutExpired, OSError):
                cleanup_complete = False
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
        selector.close()
        for number, handler in previous.items():
            signal.signal(number, handler)
    if cancelled and reason == "completed":
        reason = "cancelled"
    if (not cleanup_complete or later_failures) and reason == "completed":
        reason = "cleanup"
    elif reason == "completed" and exit_code != 0:
        reason = "exit"
    result = {"reason": reason, "exit_code": exit_code, "cancel_signal": cancelled,
              "cleanup_complete": cleanup_complete, "samples": samples,
              "residual_cleanup": residual_cleanup,
              "sampled_session_peak_kib": peak, "elapsed_seconds": time.monotonic() - started,
              "limits": vars(limits), "output_bytes": counts,
              "later_failures": sorted(later_failures),
              "scope": "owned session; new-session escapes unsupported"}
    result["output_omitted"] = {}
    result["excerpt_truncated"] = {}
    for name, value in buffers.items():
        omitted = (reason not in ("completed", "exit") or residual_cleanup
                   or not cleanup_complete or bool(later_failures) or name not in eof
                   or counts[name] > limits.output_bytes)
        safe = "<omitted: incomplete or oversized stream>" if omitted else redacted(bytes(value), secrets)
        result["output_omitted"][name] = omitted
        result["excerpt_truncated"][name] = reason != "completed" and len(safe) > 4096
        result[name] = safe if reason == "completed" else safe[-4096:]
    return result


def main():
    if len(sys.argv) != 2 or re.fullmatch(r"[0-9a-f]{40}", sys.argv[1]) is None:
        raise SystemExit("usage: nested_supervision.py <reviewed head SHA>")
    fixture = json.loads(Path("tests/fixtures/mailbox.json").read_text())
    secrets = (fixture["password"], fixture["user"], "ts_test_key_0123456789",
               "\0" + fixture["user"] + "\0" + fixture["password"])
    result = supervise(["/usr/bin/time", "-v", sys.executable, "-B",
                        "tests/test-mime-corpus.py", "--nested-resources"], secrets=secrets)
    for name in ("stdout", "stderr"):
        print(f"NESTED_{name.upper()}_BEGIN")
        print(result.pop(name))
        print(f"NESTED_{name.upper()}_END")
    result["source_head"] = sys.argv[1]
    print("NESTED_SUPERVISION_JSON " + json.dumps(result, sort_keys=True))
    return int(result["reason"] != "completed")


if __name__ == "__main__":
    raise SystemExit(main())
