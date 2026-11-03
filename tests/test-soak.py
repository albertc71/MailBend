#!/usr/bin/env python3
"""Synthetic Linux MCP session soak. No provider or real-client claims."""
import argparse
import contextlib
import json
import hashlib
import platform
import math
import os
from pathlib import Path
import queue
import resource
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
BURST = 10
WARMUP = 50
RSS_LIMIT_KIB = 1024 * 1024
RSS_GROWTH_KIB = 256 * 1024
SAMPLE_SECONDS = 0.1


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def check_metrics(latencies, samples, warmup_end):
    warm = [rss for stamp, rss in samples if stamp <= warmup_end]
    measured = [rss for stamp, rss in samples if stamp > warmup_end]
    assert warm and measured, "RSS sampling missed warm-up or measurement"
    assert max(measured) <= RSS_LIMIT_KIB, "core RSS exceeded 1 GiB"
    assert max(measured) <= max(warm) + RSS_GROWTH_KIB, "core RSS grew over 256 MiB after warm-up"
    tenth = len(latencies) // 10
    first, last = percentile(latencies[:tenth], .95), percentile(latencies[-tenth:], .95)
    assert last <= 3 * first, "last-tenth p95 latency exceeded drift bound"
    return {"first_tenth_p95_seconds": first, "last_tenth_p95_seconds": last, "p95_drift_ratio": last / first,
            "p50_seconds": percentile(latencies, .5), "p95_seconds": percentile(latencies, .95),
            "warmup_peak_rss_kib": max(warm), "measured_peak_rss_kib": max(measured)}


def request(ident, index):
    # Identical ten-call mixes make first/last-tenth queueing comparable.
    calls = [("tools/list", {}), ("tools/call", {"name": "mail_probe", "arguments": {}}),
             ("tools/call", {"name": "mail_search", "arguments": {"limit": 2}}),
             ("tools/call", {"name": "mail_get", "arguments": {"uid": 1}}),
             ("tools/call", {"name": "mail_flag", "arguments": {"uids": [1], "uidvalidity": 1700000001}}),
             ("tools/call", {"name": "mail_unflag", "arguments": {"uids": [1], "uidvalidity": 1700000001}}),
             ("soak/unknown", {}),
             ("tools/call", {"name": "mail_get", "arguments": {"uid": 0}}),
             ("tools/call", {"name": "mail_search", "arguments": {"limit": 2}}),
             ("tools/call", {"name": "mail_get", "arguments": {"uid": 1}})]
    method, params = calls[index % BURST]
    return {"jsonrpc": "2.0", "id": ident, "method": method, "params": params}


def check_reply(reply, sent):
    assert reply.get("jsonrpc") == "2.0" and type(reply.get("id")) is int, "invalid reply envelope"
    assert reply["id"] == sent["id"], "missing, duplicate, unsolicited or out-of-order reply"
    method, params = sent["method"], sent["params"]
    if method == "soak/unknown":
        assert reply.get("error", {}).get("code") == -32601, "unknown method was not refused"
        return
    assert "error" not in reply and isinstance(reply.get("result"), dict), "unexpected RPC error"
    result = reply["result"]
    if method == "tools/list":
        assert any(tool.get("name") == "mail_get" for tool in result.get("tools", [])), "empty tool list"
        return
    if params["arguments"].get("uid") == 0:
        assert result.get("isError") is True, "invalid UID was not refused"
        return
    assert not result.get("isError"), "successful operation returned a tool error"
    data = result.get("structuredContent")
    assert isinstance(data, dict), "missing structured tool result"
    name = params["name"]
    if name in ("mail_flag", "mail_unflag"):
        assert data.get("changed") == [1] and data.get("flagged") == (name == "mail_flag"), "flag work did not happen"
    elif name == "mail_get":
        assert data.get("uid") == 1 and "Want to grab lunch tomorrow" in data.get("text", ""), "message body was not fetched"
    elif name == "mail_search":
        assert [m.get("uid") for m in data.get("messages", [])] == [6, 5], "search did not read fixture"
    else:
        assert data.get("ok") is True and data.get("tls_verified") is True and data.get("imap_host") == "localhost", "probe did not verify local IMAP"


def ready_line(stream, timeout=15):
    deadline, data = time.monotonic() + timeout, b""
    while b"\n" not in data:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([stream], [], [], remaining)[0], "fake server startup timeout"
        chunk = os.read(stream.fileno(), 1024)
        assert chunk and len(data) + len(chunk) <= 4096, "invalid fake server readiness"
        data += chunk
    return data.split(b"\n", 1)[0].decode().split()


def write_batch(proc, items, timeout):
    payload = b"".join((json.dumps(item) + "\n").encode() for item in items)
    deadline = time.monotonic() + timeout
    while payload:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([], [proc.stdin], [], remaining)[1], "MCP input write timeout"
        try:
            size = os.write(proc.stdin.fileno(), payload)
            payload = payload[size:]
        except BlockingIOError:
            continue


def child_limits():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_FSIZE, (64 * 1024 ** 2, 64 * 1024 ** 2))


def stop(proc):
    if proc is not None:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=10)


def run(profile):
    count, budget = (500, 180) if profile == "short" else (5000, 1800)
    core = ROOT / "bin/mailbend-core"
    assert core.is_file() and os.access(core, os.X_OK), "build first: scripts/install.sh"
    fake = session = reader = sampler = None
    finished = threading.Event()
    samples, sampling_errors = [], []
    replies = queue.Queue(maxsize=16)
    with tempfile.TemporaryDirectory(prefix="mailbend-soak-") as directory:
        work = Path(directory)
        clean = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(work),
                 "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "BEND_NO_TELEMETRY": "1",
                 "MAILBEND_TYPESAFE": "0"}
        with (work / "diagnostics").open("w+b") as diagnostics:
            try:
                subprocess.run(["sh", str(ROOT / "tests/gen-test-certs.sh"), str(work / "certs")],
                               check=True, env=clean, stdout=diagnostics, stderr=diagnostics, timeout=60)
                fixture = json.loads((ROOT / "tests/fixtures/mailbox.json").read_text())
                fake = subprocess.Popen([sys.executable, str(ROOT / "tests/fake_mail_server.py"),
                    "--fixture", str(ROOT / "tests/fixtures/mailbox.json"), "--certdir", str(work / "certs"),
                    "--state", str(work / "state.json"), "--log", str(work / "commands.jsonl")],
                    stdout=subprocess.PIPE, stderr=diagnostics, env=clean, start_new_session=True, preexec_fn=child_limits)
                ready = ready_line(fake.stdout)
                assert ready[0] == "READY", "fake server did not start"
                ports = dict(part.split("=") for part in ready[1:])
                env = dict(clean, MAILBEND_EMAIL=fixture["user"], MAILBEND_APP_PASSWORD=fixture["password"],
                           MAILBEND_IMAP_HOST="localhost", MAILBEND_IMAP_PORT=ports["imap"],
                           MAILBEND_SMTP_HOST="localhost", MAILBEND_SMTP_PORT=ports["smtp"],
                           MAILBEND_CA_FILE=str(work / "certs/ca.pem"), MAILBEND_TIMEOUT_MS="10000")
                session = subprocess.Popen([str(ROOT / "scripts/mailbend"), "mcp"], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=diagnostics, env=env, start_new_session=True, preexec_fn=child_limits)

                os.set_blocking(session.stdin.fileno(), False)

                def read_replies():
                    try:
                        while True:
                            line = session.stdout.readline(4 * 1024 * 1024)
                            received = time.monotonic()
                            if not line:
                                replies.put((received, None), timeout=1)
                                return
                            assert line.endswith(b"\n"), "oversized or unterminated MCP reply"
                            replies.put((received, json.loads(line)), timeout=1)
                    except Exception:
                        with contextlib.suppress(queue.Full):
                            replies.put((time.monotonic(), {"reader_failed": True}), timeout=1)

                reader = threading.Thread(target=read_replies, daemon=True)
                reader.start()
                hello = {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
                    "protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "synthetic-soak", "version": "1"}}}
                write_batch(session, [hello], 10)
                _, response = replies.get(timeout=30)
                assert response and response.get("id") == 0 and "result" in response, "initialization failed"
                # Pipe stdin makes the adapter exec the core, retaining this PID.
                assert Path(f"/proc/{session.pid}/exe").resolve() == core.resolve(), "RSS target is not the compiled core"

                def sample():
                    while not finished.is_set():
                        try:
                            status = Path(f"/proc/{session.pid}/status").read_text()
                            rss = next(int(line.split()[1]) for line in status.splitlines() if line.startswith("VmRSS:"))
                            samples.append((time.monotonic(), rss))
                            if rss > RSS_LIMIT_KIB:
                                sampling_errors.append("core RSS exceeded 1 GiB")
                                return
                        except (OSError, StopIteration, ValueError):
                            sampling_errors.append("core RSS could not be read")
                            return
                        finished.wait(SAMPLE_SECONDS)

                sampler = threading.Thread(target=sample, daemon=True)
                sampler.start()
                started = time.monotonic()
                latencies = []
                warmup_end = None
                for offset in range(0, WARMUP + count, BURST):
                    batch = [request(i + 1, i) for i in range(offset, offset + BURST)]
                    sent_at = time.monotonic()
                    write_batch(session, batch, min(10, max(0, started + budget - time.monotonic())))
                    for item in batch:
                        remaining = started + budget - time.monotonic()
                        assert remaining > 0, "soak time budget exceeded"
                        received, reply = replies.get(timeout=min(30, remaining))
                        assert reply is not None, "core exited before completing requests"
                        check_reply(reply, item)
                        assert not sampling_errors, "RSS sampling failed or core exceeded 1 GiB"
                        if offset >= WARMUP:
                            latencies.append(received - sent_at)
                    if offset + BURST == WARMUP:
                        warmup_end = time.monotonic()
                finished.set(); sampler.join(timeout=2)
                assert not sampling_errors, "RSS sampling failed"
                elapsed = time.monotonic() - started
                assert elapsed <= budget, "soak time budget exceeded"
                session.stdin.close()
                _, trailing = replies.get(timeout=10)
                assert trailing is None, "extra reply after last request"
                assert session.wait(timeout=10) == 0, "core failed at EOF"
                reader.join(timeout=2)
                metrics = check_metrics(latencies, samples, warmup_end)
                state = json.loads((work / "state.json").read_text())
                message = next(m for m in state["mailboxes"]["INBOX"]["messages"] if m["uid"] == 1)
                assert "\\Flagged" not in message["flags"], "flag/unflag did not restore fixture"
                # No persisted output contains messages, arguments or environment.
                print(json.dumps({"profile": profile, "core_sha256": hashlib.sha256(core.read_bytes()).hexdigest(),
                    "python": platform.python_version(), "platform": platform.platform(),
                    "fixture_sha256": hashlib.sha256((ROOT / "tests/fixtures/mailbox.json").read_bytes()).hexdigest(),
                    "measured_requests": count, "warmup_requests": WARMUP,
                    "burst": BURST, "elapsed_seconds": elapsed, "rss_sample_interval_seconds": SAMPLE_SECONDS,
                    "rss_curve": [[round(stamp - started, 3), rss] for stamp, rss in samples],
                    **metrics}, sort_keys=True))
            finally:
                finished.set()
                try:
                    stop(session)
                finally:
                    stop(fake)
                    for thread in (reader, sampler):
                        if thread is not None:
                            thread.join(timeout=3)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("short", "long"), default="short")
    args = parser.parse_args()
    try:
        run(args.profile)
    except (AssertionError, OSError, ValueError, queue.Empty, subprocess.SubprocessError) as error:
        # Do not echo arbitrary subprocess output or arguments containing test credentials.
        print("FAIL MCP soak: " + (str(error) if isinstance(error, AssertionError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
