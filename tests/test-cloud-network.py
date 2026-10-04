#!/usr/bin/env python3
"""Real local HTTPS DNS + TLS IMAP/STARTTLS SMTP, with no external network.

Run after scripts/install.sh. All services use ephemeral loopback ports
and are stopped/joined by the test that owns them; credentials are fixtures.
"""
import contextlib
import http.server
import ipaddress
import json
import os
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "tests/fixtures/mailbox.json"
FIX = json.loads(FIXTURE.read_text())
HELPER = ROOT / "bin/mailbend-tls"


class Resolver(http.server.ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self, certs, cert="server", answers=("127.0.0.1", "::1"), mode="ok"):
        super().__init__(("127.0.0.1", 0), DnsHandler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(certs / f"{cert}.pem", certs / f"{cert}-key.pem")
        self.socket = ctx.wrap_socket(self.socket, server_side=True)
        self.answers, self.mode, self.queries = answers, mode, []

    @property
    def url(self):
        return f"https://localhost:{self.server_port}/dns-query"


class DnsHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        wire = self.rfile.read(int(self.headers["Content-Length"]))
        self.server.queries.append((self.path, wire, dict(self.headers)))
        if self.server.mode == "silent":
            time.sleep(1)
            return
        if self.server.mode == "http-error":
            self.send_error(503)
            return
        end = 12
        while wire[end]:
            end += 1 + wire[end]
        end += 1
        qtype, qclass = struct.unpack("!HH", wire[end:end + 4])
        records = []
        if self.server.mode == "ok":
            for address in self.server.answers:
                ip = ipaddress.ip_address(address)
                if qtype == (1 if ip.version == 4 else 28):
                    # TTL zero deliberately prevents reusing these answers.
                    records.append(b"\xc0\x0c" + struct.pack("!HHIH", qtype, qclass, 0, len(ip.packed)) + ip.packed)
        flags = 0x8183 if self.server.mode == "nxdomain" else 0x8180
        reply = wire[:2] + struct.pack("!HHHHH", flags, 1, len(records), 0, 0) + wire[12:end + 4] + b"".join(records)
        if self.server.mode == "malformed":
            reply = b"not a DNS packet"
        self.send_response(200)
        self.send_header("Content-Type", "application/dns-message")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)


@contextlib.contextmanager
def dns_server(certs, **kwargs):
    server = Resolver(certs, **kwargs)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class CloudNetworkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory(prefix="mailbend-network-")
        cls.certs = Path(cls.work.name) / "certs"
        subprocess.run(["sh", str(ROOT / "tests/gen-test-certs.sh"), str(cls.certs)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    @contextlib.contextmanager
    def mail_server(self, cert="server", bind="127.0.0.1"):
        with tempfile.TemporaryDirectory(dir=self.work.name) as work:
            log = Path(work) / "log.jsonl"
            cmd = ["python3", str(ROOT / "tests/fake_mail_server.py"), "--certdir", str(self.certs),
                   "--fixture", str(FIXTURE), "--state", work + "/state.json", "--log", str(log),
                   "--cert-name", cert, "--require-sni", "mailbend.test", "--bind-host", bind]
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                # Bound startup even if the fixture fails before printing READY.
                import select
                self.assertTrue(select.select([proc.stdout], [], [], 5)[0], "server startup timed out")
                ready = proc.stdout.readline().split()
                self.assertTrue(ready and ready[0] == "READY", "server failed to start")
                ports = dict(part.split("=") for part in ready[1:])
                yield ports, log
            finally:
                proc.terminate()
                try:
                    proc.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.communicate()

    def mail_env(self, ports, **overrides):
        # Do not inherit real credentials, resolver overrides or HTTP proxies.
        env = {"PATH": os.defpath, "MAILBEND_EMAIL": FIX["user"],
               "MAILBEND_APP_PASSWORD": FIX["password"], "MAILBEND_CA_FILE": str(self.certs / "ca.pem"),
               "MAILBEND_TIMEOUT_MS": "2000", "MAILBEND_IMAP_HOST": "mailbend.test",
               "MAILBEND_SMTP_HOST": "mailbend.test", "MAILBEND_IMAP_PORT": ports["imap"],
               "MAILBEND_SMTP_PORT": ports["smtp"]}
        env.update(overrides)
        return env

    def call(self, proto, ports, expected=0, **overrides):
        env = self.mail_env(ports, **overrides)
        script = b"a1 CAPABILITY\r\n" if proto == "imap" else b""
        result = subprocess.run([str(HELPER), proto], env=env, input=script, capture_output=True, timeout=6)
        self.assertNotIn(FIX["password"].encode(), result.stdout + result.stderr, "fixture credential leaked")
        self.assertEqual(result.returncode, expected, "unexpected helper exit (output withheld)")
        return result

    def test_numeric_override_preserves_sni_and_certificate_name(self):
        with self.mail_server() as (ports, _):
            for proto in ("imap", "smtp"):
                with self.subTest(proto=proto):
                    self.call(proto, ports, **{f"MAILBEND_{proto.upper()}_CONNECT_IP": "127.0.0.1"})

    def test_ipv6_override(self):
        try:
            with socket.socket(socket.AF_INET6) as sock:
                sock.bind(("::1", 0))
        except OSError:
            self.skipTest("IPv6 loopback unavailable")
        with self.mail_server(bind="::1") as (ports, _):
            self.call("imap", ports, MAILBEND_IMAP_CONNECT_IP="::1")
            # Existing bare IPv6 *_HOST values still reach TLS, where this
            # DNS-only certificate must fail IP identity verification.
            self.call("imap", ports, expected=3, MAILBEND_IMAP_HOST="::1")

    def test_invalid_override_rejected_before_connect(self):
        with self.mail_server() as (ports, log):
            for ip in ("localhost", "127.0.0.1:993", "127.0.0.1,127.0.0.2"):
                with self.subTest(ip=ip):
                    self.call("imap", ports, expected=2, MAILBEND_IMAP_CONNECT_IP=ip)
            self.assertFalse(log.exists() and log.read_text())

    def test_doh_uses_all_addresses_and_refreshes_each_session(self):
        with self.mail_server() as (ports, _), dns_server(self.certs, answers=("127.0.0.2", "127.0.0.1", "::1")) as dns:
            for proto in ("imap", "smtp", "imap"):
                before = len(dns.queries)
                self.call(proto, ports, MAILBEND_DOH_URL=dns.url)
                self.assertGreater(len(dns.queries), before)
            for path, wire, headers in dns.queries:
                self.assertEqual(path, "/dns-query")
                self.assertNotIn("Authorization", headers)
                self.assertNotIn(FIX["password"].encode(), wire)

    def test_override_takes_precedence_over_doh(self):
        with self.mail_server() as (ports, _), dns_server(self.certs, mode="nxdomain") as dns:
            self.call("imap", ports, MAILBEND_DOH_URL=dns.url, MAILBEND_IMAP_CONNECT_IP="127.0.0.1")
            self.assertEqual(dns.queries, [])

    def test_cloud_launcher_cli_and_long_lived_mcp(self):
        with self.mail_server() as (ports, _), dns_server(self.certs) as dns:
            env = self.mail_env(ports, MAILBEND_DOH_URL=dns.url, MAILBEND_READ_ONLY="1")
            launcher = str(ROOT / "scripts/mailbend-cloud")
            cli = subprocess.run([launcher, "call", "mail_probe"], env=env, capture_output=True, timeout=15)
            self.assertEqual(cli.returncode, 0)
            self.assertNotIn(FIX["password"].encode(), cli.stdout + cli.stderr)
            self.assertTrue(json.loads(cli.stdout)["tls_verified"])
            # One core process, two calls. Each must invoke a fresh resolver.
            queries_before = len(dns.queries)
            requests = [json.dumps({"jsonrpc": "2.0", "id": n, "method": "tools/call",
                                   "params": {"name": "mail_probe", "arguments": {}}}) for n in (1, 2)]
            mcp = subprocess.run([launcher, "mcp"], env=env, input=("\n".join(requests) + "\n").encode(),
                                 capture_output=True, timeout=20)
            self.assertEqual(mcp.returncode, 0)
            self.assertNotIn(FIX["password"].encode(), mcp.stdout + mcp.stderr)
            replies = [json.loads(line) for line in mcp.stdout.splitlines()]
            self.assertEqual([reply["id"] for reply in replies], [1, 2])
            for reply in replies:
                result = json.loads(reply["result"]["content"][0]["text"])
                self.assertTrue(result["ok"] and result["tls_verified"])
            self.assertGreaterEqual(len(dns.queries) - queries_before, 4)

    def test_doh_fails_closed(self):
        with self.mail_server() as (ports, log):
            for mode in ("nxdomain", "empty", "malformed", "http-error", "silent"):
                with self.subTest(mode=mode), dns_server(self.certs, mode=mode) as dns:
                    self.call("imap", ports, expected=3, MAILBEND_DOH_URL=dns.url, MAILBEND_TIMEOUT_MS="350")
                    self.assertTrue(dns.queries)
            self.assertFalse(log.exists() and log.read_text(), "mail reached after DNS failure")

    def test_doh_requires_https_and_valid_certificate(self):
        with self.mail_server() as (ports, log):
            self.call("imap", ports, expected=2, MAILBEND_DOH_URL="http://localhost/dns-query")
            for cert in ("wronghost", "expired", "selfsigned"):
                with self.subTest(cert=cert), dns_server(self.certs, cert=cert) as dns:
                    self.call("imap", ports, expected=3, MAILBEND_DOH_URL=dns.url)
                    self.assertEqual(dns.queries, [])
            self.assertFalse(log.exists() and log.read_text())

    def test_mail_certificate_still_checked_with_doh_and_ip(self):
        for cert in ("wronghost", "expired", "selfsigned"):
            with self.subTest(cert=cert), self.mail_server(cert=cert) as (ports, log), dns_server(self.certs) as dns:
                for proto in ("imap", "smtp"):
                    self.call(proto, ports, expected=3, MAILBEND_DOH_URL=dns.url)
                    self.call(proto, ports, expected=3, **{f"MAILBEND_{proto.upper()}_CONNECT_IP": "127.0.0.1"})
                lines = log.read_text() if log.exists() else ""
                self.assertNotIn("LOGIN", lines)
                self.assertNotIn("AUTH", lines)


if __name__ == "__main__":
    unittest.main(verbosity=2)
