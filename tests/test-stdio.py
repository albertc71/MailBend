#!/usr/bin/env python3
import json
import os
import pathlib
import resource
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
LAUNCHERS = [ROOT / "scripts/mailbend", ROOT / "scripts/mailbend-cloud"]
STDIO_BINARY = ROOT / "bin/mailbend-stdio"
ENV = {k: v for k, v in os.environ.items() if not k.startswith("MAILBEND_")}
ENV["MAILBEND_READ_ONLY"] = "1"
ENV["BEND_NO_TELEMETRY"] = "1"
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
META = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {}}


def request(method, ident=1, params=None):
    return json.dumps({"jsonrpc": "2.0", "id": ident, "method": method,
                       "params": params or {}}, ensure_ascii=False).encode() + b"\n"


def discovery(modern=False):
    if modern:
        return request("server/discover", params={"_meta": META})
    return request("initialize", params={"protocolVersion": "2025-06-18", "capabilities": {},
                                         "clientInfo": {"name": "stdio-test", "version": "1"}})


def wait_until(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError("condition did not become true within timeout")


def live(pid):
    try:
        return pathlib.Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1][0] != "Z"
    except FileNotFoundError:
        return False


class Session:
    def __init__(self, launcher, duplex=False, nonblocking=False, env=ENV):
        self.peer, child = socket.socketpair()
        child.setblocking(not nonblocking)
        self.proc = subprocess.Popen([str(launcher), "mcp"], stdin=child,
                                     stdout=child if duplex else subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=env, cwd="/", start_new_session=True)
        child.close()
        self.output = self.peer if duplex else self.proc.stdout
        self.pending = b""

    def line(self):
        deadline = time.monotonic() + 30
        while b"\n" not in self.pending:
            if not select.select([self.output], [], [], max(0, deadline - time.monotonic()))[0]:
                raise AssertionError("MCP reply did not arrive while stdin remained open")
            chunk = os.read(self.output.fileno(), 65536)
            if not chunk:
                raise AssertionError("MCP closed output before replying")
            self.pending += chunk
        line, self.pending = self.pending.split(b"\n", 1)
        return json.loads(line)

    def core_pid(self):
        path = pathlib.Path(f"/proc/{self.proc.pid}/task/{self.proc.pid}/children")
        return int(wait_until(lambda: path.read_text().strip()).split()[0])

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.peer.close()
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(timeout=10)
        for stream in (self.proc.stdout, self.proc.stderr):
            if stream is not None:
                stream.close()


class StdioTests(unittest.TestCase):
    def test_socket_discovery_before_eof(self):
        for launcher in LAUNCHERS:
            for modern in (False, True):
                for duplex, nonblocking in ((False, False), (True, False), (True, True)):
                    with self.subTest(launcher=launcher.name, modern=modern,
                                      duplex=duplex, nonblocking=nonblocking):
                        with Session(launcher, duplex, nonblocking) as session:
                            session.peer.sendall(discovery(modern))
                            self.assertEqual(session.line()["id"], 1)
                            params = {"_meta": META} if modern else {}
                            session.peer.sendall(request("tools/list", 2, params))
                            result = session.line()["result"]
                            self.assertEqual(len(result["tools"]), 7)
                            self.assertTrue(all(t["annotations"]["readOnlyHint"] for t in result["tools"]))
                            core = session.core_pid()
                            session.peer.shutdown(socket.SHUT_WR)
                            self.assertEqual(session.proc.wait(timeout=10), 0)
                            self.assertEqual(session.proc.stderr.read(), b"")
                            self.assertFalse(live(core))

    def test_pipe_file_and_empty_input(self):
        for launcher in LAUNCHERS:
            for data in (b"", discovery(), discovery(True)):
                for regular_file in (False, True):
                    with self.subTest(launcher=launcher.name, data=bool(data), file=regular_file):
                        with tempfile.TemporaryFile() as file:
                            file.write(data)
                            file.seek(0)
                            p = subprocess.run([str(launcher), "mcp"],
                                               stdin=file if regular_file else None,
                                               input=None if regular_file else data,
                                               capture_output=True, env=ENV, cwd="/",
                                               start_new_session=True, timeout=30)
                            self.assertEqual((p.returncode, p.stderr), (0, b""))
                            self.assertEqual(len(p.stdout.splitlines()), 1 if data else 0)

    def test_pipe_exec_keeps_pid(self):
        p = subprocess.Popen([str(LAUNCHERS[0]), "mcp"], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV)
        try:
            wait_until(lambda: pathlib.Path(f"/proc/{p.pid}/comm").read_text().strip() == "mailbend-core")
            self.assertEqual(pathlib.Path(f"/proc/{p.pid}/task/{p.pid}/children").read_text().strip(), "")
            out, err = p.communicate(discovery(), timeout=30)
            self.assertEqual((p.returncode, err), (0, b""))
            self.assertEqual(json.loads(out)["id"], 1)
        finally:
            if p.poll() is None:
                p.kill()
            p.wait()

    def test_split_utf8_and_unterminated_final_line(self):
        with Session(LAUNCHERS[0]) as session:
            session.peer.sendall(discovery())
            session.line()
            message = request("unknown-" + "é" * 70000, 2)
            split = message.index("é".encode()) + 1
            session.peer.sendall(message[:split])
            session.peer.sendall(message[split:-1])
            session.peer.shutdown(socket.SHUT_WR)
            self.assertEqual(session.line()["error"]["code"], -32601)
            self.assertEqual(session.proc.wait(timeout=10), 0)

    def test_invalid_utf8_stays_a_bend_error(self):
        with Session(LAUNCHERS[0]) as session:
            session.peer.sendall(b'{"jsonrpc":"2.0","method":"\xff","id":1}\n')
            self.assertEqual(session.line()["error"]["code"], -32700)

    def test_core_exits_on_oversized_line_with_input_open(self):
        with Session(LAUNCHERS[0]) as session:
            core = session.core_pid()
            failures = []
            def send():
                try:
                    session.peer.sendall(b"x" * (8 * 1024 * 1024 + 1))
                except BrokenPipeError:
                    pass
                except OSError as error:
                    failures.append(error)
            sender = threading.Thread(target=send)
            sender.start()
            try:
                self.assertEqual(session.line()["error"]["code"], -32600)
                self.assertEqual(session.proc.wait(timeout=10), 0)
            finally:
                session.peer.close()
                sender.join(timeout=10)
            self.assertFalse(sender.is_alive())
            self.assertFalse(failures)
            self.assertFalse(live(core))

    def test_signals_and_parent_death(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGKILL):
            with self.subTest(signal=sig), Session(LAUNCHERS[0]) as session:
                session.peer.sendall(discovery())
                session.line()
                core = session.core_pid()
                session.proc.send_signal(sig)
                self.assertEqual(session.proc.wait(timeout=10), -sig)
                wait_until(lambda: not live(core))

    def test_quit_status_propagates(self):
        with Session(LAUNCHERS[0]) as session:
            session.peer.sendall(discovery())
            session.line()
            core = session.core_pid()
            session.proc.send_signal(signal.SIGQUIT)
            try:
                status = session.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pattern = pathlib.Path("/proc/sys/kernel/core_pattern").read_text().strip()
                dumping = False
                owned_states = {}
                for pid in (core, session.proc.pid):
                    try:
                        state = pathlib.Path(f"/proc/{pid}/status").read_text()
                        dumping |= "CoreDumping:\t1" in state
                        owned_states[pid] = [line for line in state.splitlines()
                                             if line.startswith(("State:", "CoreDumping:", "SigPnd:"))]
                    except FileNotFoundError:
                        owned_states[pid] = ["exited"]
                print(f"SIGQUIT timeout: core_pattern={pattern!r}; owned_states={owned_states}",
                      file=sys.stderr)
                if pattern.startswith("|") and dumping:
                    self.skipTest(f"{pattern.split()[0]} delayed SIGQUIT; kernel reports CoreDumping=1")
                raise
            self.assertEqual(status, -signal.SIGQUIT)
            self.assertFalse(live(core))

    def test_controlled_child_signal_statuses(self):
        # A controlled OS child isolates forwarding from the host crash collector.
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = pathlib.Path(directory) / "bin"
            bin_dir.mkdir()
            helper = bin_dir / "mailbend-stdio"
            shutil.copy2(ROOT / "bin/mailbend-stdio", helper)
            core = bin_dir / "mailbend-core"
            core.write_text(f"#!{sys.executable}\nimport os, signal\n"
                            "signal.signal(signal.SIGQUIT, lambda *_: os._exit(73))\n"
                            "signal.signal(signal.SIGPIPE, signal.SIG_DFL)\n"
                            "os.write(1, b'R')\nwhile True: signal.pause()\n")
            core.chmod(0o755)
            with Session(helper) as session:
                self.assertTrue(select.select([session.proc.stdout], [], [], 10)[0])
                self.assertEqual(session.proc.stdout.read(1), b"R")
                child = session.core_pid()
                session.proc.send_signal(signal.SIGQUIT)
                self.assertEqual(session.proc.wait(timeout=10), 73)
                self.assertFalse(live(child))
            with Session(helper) as session:
                self.assertTrue(select.select([session.proc.stdout], [], [], 10)[0])
                self.assertEqual(session.proc.stdout.read(1), b"R")
                child = session.core_pid()
                os.kill(child, signal.SIGPIPE)
                self.assertEqual(session.proc.wait(timeout=10), 128 + signal.SIGPIPE)
                self.assertFalse(live(child))

    def test_child_signal_status_propagates(self):
        with Session(LAUNCHERS[0]) as session:
            session.peer.sendall(discovery())
            session.line()
            os.kill(session.core_pid(), signal.SIGTERM)
            self.assertEqual(session.proc.wait(timeout=10), -signal.SIGTERM)

    def test_parent_death_during_startup(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=sig), Session(LAUNCHERS[0]) as session:
                core = session.core_pid()
                session.proc.send_signal(sig)
                self.assertEqual(session.proc.wait(timeout=10), -sig)
                wait_until(lambda: not live(core))

    def test_client_disconnect_mid_request(self):
        with Session(LAUNCHERS[0], duplex=True) as session:
            session.peer.sendall(discovery())
            session.line()
            core = session.core_pid()
            session.peer.sendall(b'{"jsonrpc":"2.0","method":')
            session.peer.close()
            session.proc.wait(timeout=10)
            self.assertFalse(live(core))

    def test_stopped_core_terminates_after_parent_death(self):
        with Session(LAUNCHERS[0]) as session:
            session.peer.sendall(discovery())
            session.line()
            core = session.core_pid()
            os.kill(core, signal.SIGSTOP)
            try:
                wait_until(lambda: pathlib.Path(f"/proc/{core}/stat").read_text().split(") ", 1)[1][0] == "T")
                session.proc.kill()
                self.assertEqual(session.proc.wait(timeout=10), -signal.SIGKILL)
                # Exercise the real core; the separate input-independent child
                # distinguishes the death guard from orphan-group HUP/CONT + EOF.
                wait_until(lambda: not live(core))
            finally:
                if live(core):
                    os.kill(core, signal.SIGKILL)
                    wait_until(lambda: not live(core))

    def test_parent_death_guard_kills_input_independent_child(self):
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = pathlib.Path(directory) / "bin"
            bin_dir.mkdir()
            helper = bin_dir / "mailbend-stdio"
            shutil.copy2(STDIO_BINARY, helper)
            core = bin_dir / "mailbend-core"
            core.write_text(f"#!{sys.executable}\nimport os, signal\n"
                            "signal.signal(signal.SIGHUP, signal.SIG_IGN)\n"
                            "os.write(1, b'R')\nwhile True: signal.pause()\n")
            core.chmod(0o755)
            with Session(helper) as session:
                self.assertTrue(select.select([session.proc.stdout], [], [], 10)[0])
                self.assertEqual(session.proc.stdout.read(1), b"R")
                child = session.core_pid()
                os.kill(child, signal.SIGSTOP)
                try:
                    wait_until(lambda: pathlib.Path(f"/proc/{child}/stat").read_text().split(") ", 1)[1][0] == "T")
                    session.proc.kill()
                    self.assertEqual(session.proc.wait(timeout=10), -signal.SIGKILL)
                    # Orphan groups receive HUP+CONT. This child ignores HUP and
                    # never reads EOF, so only the death guard can end it.
                    wait_until(lambda: not live(child))
                finally:
                    if live(child):
                        os.kill(child, signal.SIGKILL)
                        wait_until(lambda: not live(child))
                    wait_until(lambda: not pathlib.Path(f"/proc/{child}").exists())

    def test_queued_input_survives_socket_hangup(self):
        with Session(LAUNCHERS[0]) as session:
            session.peer.sendall(discovery() + request("tools/list", 2)
                                 + request("unknown-" + "x" * 70000, 3))
            session.peer.close()
            self.assertEqual(session.line()["id"], 1)
            self.assertEqual(session.line()["id"], 2)
            reply = session.line()
            self.assertEqual((reply["id"], reply["error"]["code"]), (3, -32601))
            self.assertEqual(session.proc.wait(timeout=10), 0)

    def test_backpressure_still_forwards_signals(self):
        with Session(LAUNCHERS[0]) as session:
            session.peer.sendall(discovery())
            session.line()
            core = session.core_pid()
            os.kill(core, signal.SIGSTOP)
            try:
                session.peer.setblocking(False)
                while True:
                    try:
                        session.peer.send(b"x" * 65536)
                    except BlockingIOError:
                        break
                session.proc.terminate()
                def term_pending():
                    status = pathlib.Path(f"/proc/{core}/status").read_text()
                    pending = next(l for l in status.splitlines() if l.startswith("ShdPnd:")).split()[1]
                    return int(pending, 16) & (1 << (signal.SIGTERM - 1))
                wait_until(term_pending)
            finally:
                os.kill(core, signal.SIGCONT)
            self.assertEqual(session.proc.wait(timeout=10), -signal.SIGTERM)
            self.assertFalse(live(core))

    def test_missing_core_exits_and_reaps(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = pathlib.Path(directory) / "bin/mailbend-stdio"
            helper.parent.mkdir()
            shutil.copy2(ROOT / "bin/mailbend-stdio", helper)
            with Session(helper) as session:
                self.assertEqual(session.proc.wait(timeout=10), 2)
                self.assertEqual(session.proc.stdout.read(), b"")
                self.assertIn(b"core is missing", session.proc.stderr.read())

    def test_bend_home_fallback_without_path_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "bin").mkdir()
            helper = root / "bin/mailbend-stdio"
            shutil.copy2(ROOT / "bin/mailbend-stdio", helper)
            for name in ("main.bend", "src"):
                (root / name).symlink_to(ROOT / name)
            env = dict(ENV, PATH="/usr/bin:/bin")
            with Session(helper, env=env) as session:
                session.peer.sendall(discovery())
                self.assertEqual(session.line()["id"], 1)
                session.peer.shutdown(socket.SHUT_WR)
                self.assertEqual(session.proc.wait(timeout=30), 0)
                self.assertEqual(session.proc.stderr.read(), b"")

    def test_bypass_exposes_original_socket_failure(self):
        with Session(ROOT / "bin/mailbend-core") as session:
            self.assertEqual(session.proc.wait(timeout=10), 6)
            self.assertEqual(session.proc.stdout.read(), b"")
            self.assertIn(b"No such device or address", session.proc.stderr.read())


if __name__ == "__main__":
    unittest.main(verbosity=2)
