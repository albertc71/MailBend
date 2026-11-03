#!/usr/bin/env python3
"""Same-runner comparison using an immutable synthetic soak; never real mail."""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time

HARNESS_SHA256 = "1357eba0b6ccdf0f04368d4e00aff7de281c5cf6b77c94358866cbc3212bd110"


def clean_env(home):
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home),
            "LANG": "C.UTF-8", "BEND_NO_TELEMETRY": "1", "MAILBEND_TYPESAFE": "0"}


def startup(root, env):
    started = time.monotonic()
    p = subprocess.Popen([str(root / "scripts/mailbend"), "mcp"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env,
                         start_new_session=True)
    try:
        p.stdin.write(b'{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}\n')
        p.stdin.flush()
        data = b""
        while b"\n" not in data:
            remaining = started + 30 - time.monotonic()
            assert remaining > 0 and select.select([p.stdout], [], [], remaining)[0], "startup timeout"
            chunk = os.read(p.stdout.fileno(), 65536)
            assert chunk and len(data) + len(chunk) <= 1024 * 1024, "invalid startup output"
            data += chunk
        reply = json.loads(data.split(b"\n", 1)[0])
        elapsed = time.monotonic() - started
        assert reply.get("id") == 0 and "result" in reply, "startup response failed"
        rss = next(int(line.split()[1]) for line in Path(f"/proc/{p.pid}/status").read_text().splitlines()
                   if line.startswith("VmRSS:"))
        p.stdin.close()
        assert p.wait(timeout=10) == 0, "startup EOF failed"
        return {"first_reply_seconds": elapsed, "rss_after_first_reply_kib": rss}
    finally:
        if p.returncode is None:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait(timeout=10)
        for stream in (p.stdin, p.stdout):
            stream.close()


def process_identity(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return fields[19], fields[0], int(fields[2]), int(fields[1])
    except (FileNotFoundError, ProcessLookupError):
        return None


def descendants(pid):
    # Scan parent IDs: /proc/<pid>/task/<pid>/children is unavailable in some
    # sandboxed Linux environments, and can miss children of other threads.
    processes = {}
    for path in Path("/proc").glob("[0-9]*/stat"):
        child_pid = int(path.parent.name)
        identity = process_identity(child_pid)
        if identity is not None:
            processes[child_pid] = identity
    found, parents = {}, {pid}
    while parents:
        children = {child_pid: identity for child_pid, identity in processes.items()
                    if identity[3] in parents and child_pid not in found}
        found.update(children)
        parents = set(children)
    return found


def enable_subreaper():
    # This dedicated serial driver owns its subprocess tree, including a helper
    # orphaned if the wrapper exits before closing an inherited output pipe.
    assert ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0, "cannot own comparison descendants"


def reap_timeout(proc):
    owned = descendants(os.getpid())
    # SIGTERM becomes an exception in the wrapper, so frozen_soak.run finally
    # can kill and reap its independently sessioned core and fake server.
    if proc.poll() is None:
        proc.terminate()
    try:
        proc.wait(timeout=45)
    except subprocess.TimeoutExpired:
        pass
    for pid, identity in owned.items():
        current = process_identity(pid)
        if current is not None and current[0] == identity[0] and current[1] not in ("Z", "X"):
            try:
                os.killpg(current[2], signal.SIGKILL)
            except ProcessLookupError:
                pass
    if proc.poll() is None:
        proc.kill()
    proc.communicate(timeout=10)
    deadline = time.monotonic() + 10
    while True:
        live = [pid for pid, old in owned.items() if (now := process_identity(pid)) is not None
                and now[0] == old[0] and now[1] not in ("Z", "X")]
        if not live:
            for pid in owned:
                try:
                    os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    pass
            return
        assert time.monotonic() < deadline, "comparison child cleanup failed"
        time.sleep(.05)


def stop_requested(_signum, _frame):
    raise AssertionError("comparison wrapper deadline exceeded")


def child(root, harness):
    spec = importlib.util.spec_from_file_location("frozen_soak", harness)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.ROOT = root
    signal.signal(signal.SIGTERM, stop_requested)
    try:
        module.run("short")
    except Exception:
        # The frozen harness emits safe progress; never echo arbitrary exceptions.
        return 1
    return 0


def check_apparatus(roots, frozen_root):
    apparatus = ("tests/fixtures/mailbox.json", "tests/fake_mail_server.py", "tests/gen-test-certs.sh")
    hashes = {path: hashlib.sha256((frozen_root / path).read_bytes()).hexdigest() for path in apparatus}
    for root in roots:
        for path, expected in hashes.items():
            assert hashlib.sha256((root / path).read_bytes()).hexdigest() == expected, "comparison apparatus differs"
    return hashes


def comparison_failed(results):
    assert sorted(r["side"] for r in results) == ["candidate", "candidate", "reference", "reference"], "incomplete comparison"
    return int(any(r["exit_code"] != 0 for r in results if r["side"] == "candidate"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--child", type=Path)
    args = parser.parse_args()
    assert hashlib.sha256(args.harness.read_bytes()).hexdigest() == HARNESS_SHA256, "frozen harness changed"
    if args.child:
        return child(args.child.resolve(), args.harness.resolve())
    enable_subreaper()
    roots = {"reference": args.reference.resolve(), "candidate": args.candidate.resolve()}
    hashes = check_apparatus(roots.values(), args.harness.resolve().parent.parent)
    print(json.dumps({"frozen_harness_sha256": HARNESS_SHA256, "apparatus_sha256": hashes}), flush=True)
    results = []
    with tempfile.TemporaryDirectory(prefix="schema-comparison-") as home:
        env = clean_env(home)
        for pair, order in enumerate((('reference', 'candidate'), ('candidate', 'reference'))):
            for side in order:
                root = roots[side]
                start = startup(root, env)
                p = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--child", str(root),
                                      "--harness", str(args.harness.resolve())], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                     start_new_session=True)
                try:
                    output, _ = p.communicate(timeout=360)
                except subprocess.TimeoutExpired:
                    reap_timeout(p)
                    raise AssertionError("comparison child exceeded outer deadline") from None
                records = [json.loads(line) for line in output.splitlines() if line.startswith('{')]
                assert len(records) == 1, "missing or ambiguous soak report"
                result = {"pair": pair, "side": side, "source_sha": subprocess.check_output(
                    ["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
                    "core_sha256": hashlib.sha256((root / "bin/mailbend-core").read_bytes()).hexdigest(),
                    "exit_code": p.returncode, "startup": start, "soak": records[0]}
                results.append(result)
                print(json.dumps(result, sort_keys=True), flush=True)
    # Baseline timeouts are evidence, not hidden successful full runs. Every
    # candidate must still satisfy the frozen 180s/500-request acceptance gates.
    return comparison_failed(results)


if __name__ == "__main__":
    raise SystemExit(main())
