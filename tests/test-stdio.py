#!/usr/bin/env python3
import contextlib
import ctypes
import json
import os
import pathlib
import resource
import select
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest

import fake_mail_server as fake

ROOT = pathlib.Path(__file__).resolve().parent.parent
LAUNCHERS = [ROOT / "scripts/mailbend", ROOT / "scripts/mailbend-cloud"]
STDIO_BINARY = ROOT / "bin/mailbend-stdio"
ENV = {k: v for k, v in os.environ.items() if not k.startswith("MAILBEND_")}
ENV["MAILBEND_READ_ONLY"] = "1"
ENV["MAILBEND_TYPESAFE"] = "0"
ENV["BEND_NO_TELEMETRY"] = "1"
READ_TOOLS = {"mail_probe", "mail_list_folders", "mail_search", "mail_get",
              "mail_get_new", "mail_refresh", "mail_get_thread"}
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
    except (FileNotFoundError, ProcessLookupError):
        return False


def child_pid(pid):
    def children():
        main = pathlib.Path(f"/proc/{pid}/task/{pid}/children")
        found = main.read_text().split()
        for path in pathlib.Path(f"/proc/{pid}/task").glob("*/children"):
            if path == main:
                continue
            try:
                found.extend(path.read_text().split())
            except FileNotFoundError:
                pass
        return found
    return int(wait_until(children)[0])


class Session:
    def __init__(self, launcher, duplex=False, nonblocking=False, env=ENV, pipe=False):
        self.peer, child = (None, None) if pipe else socket.socketpair()
        if child is not None:
            child.setblocking(not nonblocking)
        self.proc = subprocess.Popen([str(launcher), "mcp"], stdin=child or subprocess.PIPE,
                                     stdout=child if duplex else subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=env, cwd="/", start_new_session=True)
        if child is not None:
            child.close()
        self.output = self.peer if duplex else self.proc.stdout
        self.pending = b""

    def send(self, data):
        if self.peer is not None:
            self.peer.sendall(data)
        else:
            self.proc.stdin.write(data)
            self.proc.stdin.flush()

    def close_input(self):
        if self.peer is not None:
            self.peer.shutdown(socket.SHUT_WR)
        else:
            self.proc.stdin.close()

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
        return child_pid(self.proc.pid) if self.peer is not None else self.proc.pid

    def __enter__(self):
        return self

    def __exit__(self, *_):
        if self.peer is not None:
            self.peer.close()
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(timeout=10)
        for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            if stream is not None:
                stream.close()


class PausedMailServer:
    def __init__(self, directory, certs, protocol):
        self.paused = threading.Event()
        self.resume = threading.Event()
        self.finished = threading.Event()
        self.data_bytes = 0
        self.errors = []
        self.fixture = json.loads((ROOT / "tests/fixtures/mailbox.json").read_text())
        self.state = fake.State(self.fixture, str(directory / "state.json"))
        self.log = directory / "commands.jsonl"
        logger = fake.Logger(str(self.log))
        tls = fake.make_ssl_context(str(certs), "server")
        owner = self

        def pause_reply(session):
            session.paused_for_stop = True
            owner.paused.set()
            if not owner.resume.wait(10):
                raise AssertionError("test did not release the paused mail reply")

        class IMAP(fake.IMAPSession):
            def send(self, text):
                if text.endswith(" COPY completed\r\n"):
                    pause_reply(self)
                super().send(text)

        class SMTP(fake.SMTPSession):
            def send(self, text):
                if text.startswith("354 "):
                    pause_reply(self)
                super().send(text)

            def cmd_data(self):
                fill = self.conn._fill
                owner.data_bytes += len(self.conn.buf)

                def count_body_bytes():
                    before = len(self.conn.buf)
                    fill()
                    owner.data_bytes += len(self.conn.buf) - before

                self.conn._fill = count_body_bytes
                try:
                    super().cmd_data()
                finally:
                    self.conn._fill = fill

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                session = None
                conn = self.request
                conn.settimeout(10)
                try:
                    if protocol == "imap":
                        conn = tls.wrap_socket(conn, server_side=True)
                        session = IMAP(conn, owner.state, logger, {"UIDPLUS", "SPECIAL-USE"})
                    else:
                        session = SMTP(conn, owner.state, logger, tls, True)
                    session.run()
                except (fake.ConnectionClosed, fake.ProtocolError, OSError):
                    pass
                except Exception as error:
                    owner.errors.append(error)
                finally:
                    (session.conn.sock if session is not None else conn).close()
                    if getattr(session, "paused_for_stop", False):
                        owner.finished.set()

        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.env = {k: v for k, v in ENV.items() if not k.startswith("MAILBEND_")}
        self.env.update(MAILBEND_EMAIL=self.fixture["user"],
                        MAILBEND_APP_PASSWORD=self.fixture["password"],
                        MAILBEND_IMAP_HOST="localhost", MAILBEND_SMTP_HOST="localhost",
                        MAILBEND_IMAP_PORT=str(self.server.server_address[1]),
                        MAILBEND_SMTP_PORT=str(self.server.server_address[1]),
                        MAILBEND_CA_FILE=str(certs / "ca.pem"), MAILBEND_TIMEOUT_MS="2000",
                        MAILBEND_TYPESAFE="0", MAILBEND_SAVE_SENT="0")

    def commands(self):
        return [json.loads(line)["line"] for line in self.log.read_text().splitlines()]

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.resume.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=10)


class StartedPlanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.certs = pathlib.Path(cls.directory.name) / "certs"
        subprocess.run(["sh", str(ROOT / "tests/gen-test-certs.sh"), str(cls.certs)],
                       check=True, capture_output=True)

    @contextlib.contextmanager
    def paused_plan(self, pipe, protocol, name, arguments):
        with tempfile.TemporaryDirectory() as directory:
            with PausedMailServer(pathlib.Path(directory), self.certs, protocol) as server:
                with Session(LAUNCHERS[0], env=server.env, pipe=pipe) as session:
                    helper = None
                    try:
                        session.send(discovery())
                        session.line()
                        session.send(request("tools/call", 2, {"name": name, "arguments": arguments}))
                        self.assertTrue(server.paused.wait(10), "helper never reached the paused reply")
                        core = session.core_pid()
                        helper = child_pid(core)
                        yield session, server, core, helper
                    finally:
                        server.resume.set()
                        if helper is not None and live(helper):
                            os.kill(helper, signal.SIGKILL)
                            wait_until(lambda: not live(helper))

    def stop_core(self, session, core):
        session.proc.terminate()
        self.assertEqual(session.proc.wait(timeout=10), -signal.SIGTERM)
        wait_until(lambda: not live(core))

    def finish_helper(self, server, helper):
        server.resume.set()
        self.assertTrue(server.finished.wait(10), "mail session did not finish")
        wait_until(lambda: not live(helper))
        self.assertEqual(server.errors, [])

    def test_started_move_finishes_after_stop(self):
        for pipe in (False, True):
            with self.subTest(pipe=pipe), self.paused_plan(
                    pipe, "imap", "mail_move",
                    {"uids": [1], "destination": "Archive", "uidvalidity": 1700000001}) as plan:
                session, server, core, helper = plan
                self.stop_core(session, core)
                self.finish_helper(server, helper)
                mailboxes = server.state.data["mailboxes"]
                self.assertNotIn(1, [m["uid"] for m in mailboxes["INBOX"]["messages"]])
                self.assertEqual([m["raw"] for m in mailboxes["Archive"]["messages"]],
                                 [server.fixture["mailboxes"]["INBOX"]["messages"][0]["raw"]])
                mutations = [line.split(" ", 1)[1] for line in server.commands()
                             if any(verb in line for verb in (" COPY ", " STORE ", " EXPUNGE"))]
                self.assertEqual(mutations, ['UID COPY 1 "Archive"',
                                            'UID STORE 1 +FLAGS.SILENT (\\Deleted)', 'UID EXPUNGE 1'])
                self.assertEqual(session.proc.stdout.read(), b"")

    def test_stop_before_smtp_body_sends_no_bytes(self):
        for pipe in (False, True):
            for stop in (False, True):
                with self.subTest(pipe=pipe, stop=stop), self.paused_plan(
                        pipe, "smtp", "mail_send",
                        {"to": "recipient@example.com", "subject": "test", "body": "test body"}) as plan:
                    session, server, core, helper = plan
                    if stop:
                        self.stop_core(session, core)
                    self.finish_helper(server, helper)
                    if stop:
                        self.assertEqual(server.data_bytes, 0)
                        self.assertEqual(server.state.data["sent"], [])
                        self.assertEqual(session.proc.stdout.read(), b"")
                    else:
                        self.assertGreater(server.data_bytes, 0)
                        self.assertEqual(len(server.state.data["sent"]), 1)
                        self.assertFalse(session.line()["result"]["isError"])
                        session.close_input()
                        self.assertEqual(session.proc.wait(timeout=10), 0)

    def test_stopped_core_does_not_remove_helper_io_timeout(self):
        for pipe in (False, True):
            with self.subTest(pipe=pipe), self.paused_plan(
                    pipe, "imap", "mail_move",
                    {"uids": [1], "destination": "Archive", "uidvalidity": 1700000001}) as plan:
                session, server, core, helper = plan
                self.stop_core(session, core)
                self.assertTrue(live(helper), "ordinary shutdown killed the helper")
                wait_until(lambda: not live(helper), timeout=5)
                self.finish_helper(server, helper)
                mailboxes = server.state.data["mailboxes"]
                self.assertIn(1, [m["uid"] for m in mailboxes["INBOX"]["messages"]])
                self.assertEqual(len(mailboxes["Archive"]["messages"]), 1)
                self.assertEqual(sum(" UID COPY " in line for line in server.commands()), 1)
                self.assertFalse(any(" UID STORE " in line for line in server.commands()))
                self.assertEqual(session.proc.stdout.read(), b"")


class SignalTargetTests(unittest.TestCase):
    def make_core(self, directory):
        root = pathlib.Path(directory)
        adapter = root / "mailbend-stdio"
        shutil.copy2(STDIO_BINARY, adapter)
        core = root / "mailbend-core"
        core.write_text(f"#!{sys.executable}\n" + '''import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(__file__).parent
if sys.argv[1:] == ["--plan"]:
    (root / "ready").touch()
    deadline = time.monotonic() + 10
    while not (root / "resume").exists():
        if time.monotonic() >= deadline:
            sys.exit(1)
        time.sleep(0.01)
    (root / "finished").touch()
else:
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
        signal.signal(sig, lambda number, _: os._exit(70 + number))
    child = subprocess.Popen([sys.executable, __file__, "--plan"],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
    while not (root / "ready").exists():
        time.sleep(0.01)
    print(json.dumps({"core": os.getpid(), "helper": child.pid}), flush=True)
    while True:
        signal.pause()
''')
        core.chmod(0o755)
        return adapter

    def stop_helper(self, pid):
        if live(pid):
            os.kill(pid, signal.SIGKILL)
            wait_until(lambda: not live(pid))

    def test_ordinary_signals_allow_started_descendant_to_finish(self):
        for pipe in (False, True):
            for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
                with self.subTest(pipe=pipe, signal=sig), tempfile.TemporaryDirectory() as directory:
                    adapter = self.make_core(directory)
                    with Session(adapter, pipe=pipe) as session:
                        pids = session.line()
                        try:
                            self.assertEqual(os.getpgid(pids["core"]), os.getpgid(pids["helper"]))
                            session.proc.send_signal(sig)
                            self.assertEqual(session.proc.wait(timeout=10), 70 + sig)
                            self.assertFalse(live(pids["core"]))
                            (pathlib.Path(directory) / "resume").touch()
                            wait_until(lambda: not live(pids["helper"]))
                            self.assertTrue((pathlib.Path(directory) / "finished").exists(),
                                            "ordinary shutdown killed the started descendant")
                        finally:
                            self.stop_helper(pids["helper"])

    def test_kill_still_stops_adapter_and_core(self):
        for pipe in (False, True):
            with self.subTest(pipe=pipe), tempfile.TemporaryDirectory() as directory:
                adapter = self.make_core(directory)
                with Session(adapter, pipe=pipe) as session:
                    pids = session.line()
                    try:
                        session.proc.kill()
                        self.assertEqual(session.proc.wait(timeout=10), -signal.SIGKILL)
                        wait_until(lambda: not live(pids["core"]))
                    finally:
                        self.stop_helper(pids["helper"])

    def test_adapter_failure_still_kills_core_group(self):
        with tempfile.TemporaryDirectory() as directory:
            adapter = self.make_core(directory)
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
                listener.bind(("127.0.0.1", 0))
                listener.listen()
                proc = subprocess.Popen([str(adapter), "mcp"], stdin=listener,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=ENV, start_new_session=True)
                pids = None
                try:
                    self.assertTrue(select.select([proc.stdout], [], [], 10)[0])
                    pids = json.loads(proc.stdout.readline())
                    with socket.create_connection(listener.getsockname()) as peer:
                        self.assertEqual(proc.wait(timeout=10), 2)
                    self.assertIn(b"cannot read stdin", proc.stderr.read())
                    wait_until(lambda: not live(pids["core"]))
                    wait_until(lambda: not live(pids["helper"]))
                    self.assertFalse((pathlib.Path(directory) / "finished").exists())
                finally:
                    if proc.poll() is None:
                        proc.kill()
                    proc.wait(timeout=10)
                    if pids is not None:
                        self.stop_helper(pids["helper"])
                    proc.stdout.close()
                    proc.stderr.close()


class StdioTests(unittest.TestCase):
    def test_replaced_adapter_starts_core(self):
        libc = ctypes.CDLL(None, use_errno=True)
        libc.ptrace.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p]
        libc.ptrace.restype = ctypes.c_long

        def trace_exec():
            if libc.ptrace(0, 0, None, None) == -1:  # PTRACE_TRACEME
                raise OSError(ctypes.get_errno(), "cannot trace adapter startup")

        for replace in (False, True):
            with self.subTest(replace=replace), tempfile.TemporaryDirectory() as directory:
                helper = pathlib.Path(directory) / "mailbend-stdio"
                shutil.copy2(STDIO_BINARY, helper)
                core = helper.parent / "mailbend-core"
                core.write_text(f"#!{sys.executable}\nimport sys\n"
                                "assert sys.argv[1:] == ['mcp']\n"
                                "sys.stdout.buffer.write(b'core: ' + sys.stdin.buffer.read())\n")
                core.chmod(0o755)
                with contextlib.ExitStack() as stack:
                    peer, child = socket.socketpair()
                    stack.enter_context(peer)
                    stack.enter_context(child)
                    proc = subprocess.Popen([str(helper), "mcp"], stdin=child,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                            env=ENV, cwd="/", preexec_fn=trace_exec)
                    child.close()
                    try:
                        # Exec stops before any adapter code, making the install/startup
                        # interleaving deterministic without a production test hook.
                        pid, status = os.waitpid(proc.pid, 0)
                        self.assertEqual(pid, proc.pid)
                        self.assertTrue(os.WIFSTOPPED(status))
                        self.assertEqual(os.WSTOPSIG(status), signal.SIGTRAP)
                        if replace:
                            replacement = helper.with_suffix(".new")
                            shutil.copy2(STDIO_BINARY, replacement)
                            replacement.replace(helper)
                            self.assertTrue(os.readlink(f"/proc/{pid}/exe").endswith(" (deleted)"))
                        self.assertEqual(libc.ptrace(17, pid, None, None), 0)  # PTRACE_DETACH
                        peer.sendall(discovery())
                        peer.shutdown(socket.SHUT_WR)
                        out, err = proc.communicate(timeout=30)
                        self.assertEqual((proc.returncode, err), (0, b""))
                        self.assertEqual(out, b"core: " + discovery())
                    finally:
                        if proc.poll() is None:
                            proc.kill()
                        proc.wait(timeout=10)
                        proc.stdout.close()
                        proc.stderr.close()

    def test_distinct_socket_stdio(self):
        for launcher in LAUNCHERS:
            for modern in (False, True):
                with self.subTest(launcher=launcher.name, modern=modern), contextlib.ExitStack() as stack:
                    pairs = [socket.socketpair() for _ in range(3)]
                    for pair in pairs:
                        for endpoint in pair:
                            stack.enter_context(endpoint)
                    peers = [pair[0] for pair in pairs]
                    children = [pair[1] for pair in pairs]
                    peers[1].settimeout(30)
                    peers[2].settimeout(10)
                    output = stack.enter_context(peers[1].makefile("rb"))
                    errors = stack.enter_context(peers[2].makefile("rb"))
                    proc = subprocess.Popen([str(launcher), "mcp"], stdin=children[0],
                                            stdout=children[1], stderr=children[2], env=ENV,
                                            cwd="/", start_new_session=True)
                    for endpoint in children:
                        endpoint.close()
                    try:
                        peers[0].sendall(discovery(modern))
                        self.assertEqual(json.loads(output.readline())["id"], 1)
                        params = {"_meta": META} if modern else {}
                        peers[0].sendall(request("tools/list", 2, params))
                        reply = json.loads(output.readline())
                        self.assertEqual(reply["id"], 2)
                        self.assertEqual({t["name"] for t in reply["result"]["tools"]}, READ_TOOLS)
                        peers[0].shutdown(socket.SHUT_WR)
                        self.assertEqual(proc.wait(timeout=10), 0)
                        self.assertEqual(output.read(), b"")
                        self.assertEqual(errors.read(), b"")
                    finally:
                        if proc.poll() is None:
                            proc.kill()
                        proc.wait(timeout=10)

    def test_typesafe_read_only_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(ENV, MAILBEND_TYPESAFE="1", MAILBEND_TYPESAFE_CONTENT="headers",
                       MAILBEND_TYPESAFE_KEY_FILE=str(pathlib.Path(directory) / "unused-key"))
            for launcher in LAUNCHERS:
                with self.subTest(launcher=launcher.name), Session(launcher, env=env) as session:
                    session.peer.sendall(discovery())
                    session.line()
                    session.peer.sendall(request("tools/list", 2))
                    tools = session.line()["result"]["tools"]
                    self.assertEqual({t["name"] for t in tools}, READ_TOOLS | {"mail_classify"})
                    self.assertTrue(all(t["annotations"]["readOnlyHint"] for t in tools))
                    session.peer.shutdown(socket.SHUT_WR)
                    self.assertEqual(session.proc.wait(timeout=10), 0)
                    self.assertEqual(session.proc.stderr.read(), b"")

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
                            self.assertEqual({t["name"] for t in result["tools"]}, READ_TOOLS)
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
            self.assertIn(b"use scripts/mailbend mcp", session.proc.stderr.read())


if __name__ == "__main__":
    unittest.main(verbosity=2)
