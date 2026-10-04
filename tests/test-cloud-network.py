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
import select
import shlex
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
FIXTURE_DATA = json.loads(FIXTURE.read_text())
HELPER = ROOT / "bin/mailbend-tls"
CLOUD_LAUNCHER = ROOT / "scripts/mailbend-cloud"

DNS_HEADER_SIZE = 12
DNS_TYPE_A = 1
DNS_TYPE_AAAA = 28
DNS_CLASS_IN = 1
DNS_RESPONSE_OK = 0x8180
DNS_RESPONSE_NXDOMAIN = 0x8183
DNS_QUESTION_POINTER = b"\xc0\x0c"  # Compressed name pointing to byte 12.
DNS_TTL_SECONDS = 60  # Fresh-session tests must not depend on an expired TTL.


def dns_question(query):
    """Read the single uncompressed question sent by the local curl client."""
    offset = DNS_HEADER_SIZE
    labels = []
    while query[offset]:
        label_size = query[offset]
        offset += 1
        labels.append(query[offset:offset + label_size].decode("ascii"))
        offset += label_size
    offset += 1  # Skip the zero-length label that terminates the name.
    question_type, question_class = struct.unpack("!HH", query[offset:offset + 4])
    return ".".join(labels), question_type, question_class, offset + 4


def dns_response(query, addresses, mode):
    if mode == "malformed":
        return b"not a DNS packet"

    _, question_type, question_class, question_end = dns_question(query)
    answers = []
    if mode == "ok":
        for address in addresses:
            ip = ipaddress.ip_address(address)
            address_type = DNS_TYPE_A if ip.version == 4 else DNS_TYPE_AAAA
            if question_type != address_type:
                continue
            record_header = struct.pack(
                "!HHIH", question_type, question_class, DNS_TTL_SECONDS, len(ip.packed)
            )
            answers.append(DNS_QUESTION_POINTER + record_header + ip.packed)

    flags = DNS_RESPONSE_NXDOMAIN if mode == "nxdomain" else DNS_RESPONSE_OK
    # Keep the transaction ID; include one question, answers, and no other records.
    header = query[:2] + struct.pack("!HHHHH", flags, 1, len(answers), 0, 0)
    question = query[DNS_HEADER_SIZE:question_end]
    return header + question + b"".join(answers)


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
        reply = dns_response(wire, self.server.answers, self.server.mode)
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
    def mail_server(self, cert="server", bind="127.0.0.1", require_sni="mailbend.test"):
        with tempfile.TemporaryDirectory(dir=self.work.name) as work:
            log = Path(work) / "log.jsonl"
            cmd = ["python3", str(ROOT / "tests/fake_mail_server.py"), "--certdir", str(self.certs),
                   "--fixture", str(FIXTURE), "--state", work + "/state.json", "--log", str(log),
                   "--cert-name", cert, "--bind-host", bind]
            if require_sni is not None:
                cmd.extend(["--require-sni", require_sni])
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                # Bound startup even if the fixture fails before printing READY.
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
        env = {
            "PATH": os.defpath,
            "MAILBEND_EMAIL": FIXTURE_DATA["user"],
            "MAILBEND_APP_PASSWORD": FIXTURE_DATA["password"],
            "MAILBEND_CA_FILE": str(self.certs / "ca.pem"),
            "MAILBEND_TIMEOUT_MS": "2000",
            "MAILBEND_IMAP_HOST": "mailbend.test",
            "MAILBEND_SMTP_HOST": "mailbend.test",
            "MAILBEND_IMAP_PORT": ports["imap"],
            "MAILBEND_SMTP_PORT": ports["smtp"],
        }
        env.update(overrides)
        return env

    def assert_no_fixture_secret(self, result):
        # Boolean assertions keep captured output out of unittest's failure log.
        leaked = FIXTURE_DATA["password"].encode() in result.stdout + result.stderr
        self.assertFalse(leaked, "fixture credential leaked (output withheld)")

    def run_helper(self, proto, ports, expected=0, **overrides):
        env = self.mail_env(ports, **overrides)
        script = b"a1 CAPABILITY\r\n" if proto == "imap" else b""
        result = subprocess.run(
            [str(HELPER), proto], env=env, input=script, capture_output=True, timeout=6
        )
        self.assert_no_fixture_secret(result)
        self.assertEqual(result.returncode, expected, "unexpected helper exit (output withheld)")
        return result

    def assert_mail_queries(self, queries):
        self.assertTrue(queries, "expected fresh DNS queries")
        question_types = []
        for path, wire, headers in queries:
            self.assertEqual(path, "/dns-query")
            self.assertFalse("Authorization" in headers, "DoH carried authorization")
            self.assertFalse(FIXTURE_DATA["password"].encode() in wire, "DoH carried fixture credential")
            name, question_type, question_class, _ = dns_question(wire)
            self.assertEqual(name, "mailbend.test")
            self.assertEqual(question_class, DNS_CLASS_IN)
            self.assertIn(question_type, (DNS_TYPE_A, DNS_TYPE_AAAA))
            question_types.append(question_type)
        return question_types

    def require_ipv6_loopback(self):
        try:
            with socket.socket(socket.AF_INET6) as sock:
                sock.bind(("::1", 0))
        except OSError:
            self.skipTest("IPv6 loopback unavailable")

    def assert_bare_ip_certificate_identity(self, address):
        # IP hosts omit DNS SNI and must verify the certificate's IP SAN.
        for cert, expected in (("ip-address", 0), ("server", 3)):
            with self.subTest(address=address, cert=cert):
                with self.mail_server(cert=cert, bind=address, require_sni=None) as (ports, _):
                    for proto in ("imap", "smtp"):
                        with self.subTest(proto=proto):
                            result = self.run_helper(
                                proto, ports, expected=expected,
                                **{f"MAILBEND_{proto.upper()}_HOST": address}
                            )
                            if cert == "server":
                                self.assertTrue(
                                    b"TLS verification failed:" in result.stderr,
                                    "DNS-only certificate must fail IP identity verification"
                                )

    def test_numeric_override_preserves_sni_and_certificate_name(self):
        with self.mail_server() as (ports, _):
            for proto in ("imap", "smtp"):
                with self.subTest(proto=proto):
                    self.run_helper(proto, ports, **{f"MAILBEND_{proto.upper()}_CONNECT_IP": "127.0.0.1"})

    def test_ipv6_override(self):
        self.require_ipv6_loopback()
        with self.mail_server(bind="::1") as (ports, _):
            for proto in ("imap", "smtp"):
                self.run_helper(proto, ports, **{f"MAILBEND_{proto.upper()}_CONNECT_IP": "::1"})

    def test_bare_ipv4_host_verifies_ip_certificate_identity(self):
        self.assert_bare_ip_certificate_identity("127.0.0.1")

    def test_bare_ipv6_host_verifies_ip_certificate_identity(self):
        self.require_ipv6_loopback()
        self.assert_bare_ip_certificate_identity("::1")

    def test_invalid_override_rejected_before_connect(self):
        with self.mail_server() as (ports, log):
            for ip in ("localhost", "127.0.0.1:993", "127.0.0.1,127.0.0.2"):
                with self.subTest(ip=ip):
                    self.run_helper("imap", ports, expected=2, MAILBEND_IMAP_CONNECT_IP=ip)
            self.assertFalse(bool(log.exists() and log.read_text()), "mail reached after invalid override")

    def test_doh_falls_back_between_addresses_and_refreshes_each_session(self):
        answers = ("127.0.0.2", "127.0.0.1", "::1")
        with self.mail_server() as (ports, _), dns_server(self.certs, answers=answers) as dns:
            for proto in ("imap", "smtp", "imap"):
                before = len(dns.queries)
                self.run_helper(proto, ports, MAILBEND_DOH_URL=dns.url)
                question_types = self.assert_mail_queries(dns.queries[before:])
                self.assertEqual(set(question_types), {DNS_TYPE_A, DNS_TYPE_AAAA})

    def test_override_takes_precedence_over_doh(self):
        with self.mail_server() as (ports, _), dns_server(self.certs, mode="nxdomain") as dns:
            self.run_helper(
                "imap", ports, MAILBEND_DOH_URL=dns.url, MAILBEND_IMAP_CONNECT_IP="127.0.0.1"
            )
            self.assertEqual(dns.queries, [])

    def test_cloud_launcher_cli_uses_doh(self):
        with self.mail_server() as (ports, _), dns_server(self.certs) as dns:
            env = self.mail_env(ports, MAILBEND_DOH_URL=dns.url, MAILBEND_READ_ONLY="1")
            cli = subprocess.run(
                [str(CLOUD_LAUNCHER), "call", "mail_probe"], env=env, capture_output=True, timeout=15
            )
            self.assert_no_fixture_secret(cli)
            self.assertEqual(cli.returncode, 0)
            self.assertTrue(json.loads(cli.stdout)["tls_verified"])
            self.assert_mail_queries(dns.queries)

    def test_cloud_launcher_empty_doh_uses_system_dns(self):
        with self.mail_server(require_sni="localhost") as (ports, _):
            # Curl can resolve localhost internally. Check the launcher's value
            # at the helper boundary as well, then run the real TLS connection.
            guard = Path(self.work.name) / "assert-empty-doh.sh"
            guard.write_text(
                '#!/bin/sh\n'
                '[ "${MAILBEND_DOH_URL+x}" = x ] && [ -z "$MAILBEND_DOH_URL" ] || exit 2\n'
                f'exec {shlex.quote(str(HELPER))} "$@"\n'
            )
            guard.chmod(0o700)
            env = self.mail_env(
                ports, MAILBEND_DOH_URL="", MAILBEND_READ_ONLY="1",
                MAILBEND_IMAP_HOST="localhost", MAILBEND_SMTP_HOST="localhost",
                MAILBEND_TLS_HELPER=str(guard)
            )
            result = subprocess.run(
                [str(CLOUD_LAUNCHER), "call", "mail_probe"], env=env, capture_output=True, timeout=15
            )
            self.assert_no_fixture_secret(result)
            self.assertEqual(result.returncode, 0)
            self.assertTrue(json.loads(result.stdout)["tls_verified"])

    def test_long_lived_mcp_refreshes_doh_each_call(self):
        with self.mail_server() as (ports, _), dns_server(self.certs) as dns:
            env = self.mail_env(ports, MAILBEND_DOH_URL=dns.url, MAILBEND_READ_ONLY="1")
            # One core process, two calls, despite still-valid DNS TTLs.
            requests = [json.dumps({
                "jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                "params": {"name": "mail_probe", "arguments": {}}
            }) for request_id in (1, 2)]
            mcp = subprocess.run(
                [str(CLOUD_LAUNCHER), "mcp"], env=env,
                input=("\n".join(requests) + "\n").encode(), capture_output=True, timeout=20
            )
            self.assert_no_fixture_secret(mcp)
            self.assertEqual(mcp.returncode, 0)
            replies = [json.loads(line) for line in mcp.stdout.splitlines()]
            self.assertEqual([reply["id"] for reply in replies], [1, 2])
            for reply in replies:
                result = json.loads(reply["result"]["content"][0]["text"])
                self.assertTrue(result["ok"] and result["tls_verified"])
            question_types = self.assert_mail_queries(dns.queries)
            self.assertGreaterEqual(question_types.count(DNS_TYPE_A), 2)
            self.assertGreaterEqual(question_types.count(DNS_TYPE_AAAA), 2)

    def test_direct_mail_ignores_http_proxy_settings(self):
        # Reserve an unused local port: accidentally using the proxy must fail.
        with socket.socket() as unused_proxy, self.mail_server() as (ports, _):
            unused_proxy.bind(("127.0.0.1", 0))
            proxy_url = f"http://127.0.0.1:{unused_proxy.getsockname()[1]}"
            proxy_env = {name: proxy_url for name in (
                "http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"
            )}
            for proto in ("imap", "smtp"):
                with self.subTest(proto=proto):
                    self.run_helper(
                        proto, ports, **proxy_env,
                        **{f"MAILBEND_{proto.upper()}_CONNECT_IP": "127.0.0.1"}
                    )

    def test_doh_fails_closed(self):
        with self.mail_server() as (ports, log):
            for mode in ("nxdomain", "empty", "malformed", "http-error", "silent"):
                with self.subTest(mode=mode), dns_server(self.certs, mode=mode) as dns:
                    self.run_helper(
                        "imap", ports, expected=3, MAILBEND_DOH_URL=dns.url, MAILBEND_TIMEOUT_MS="350"
                    )
                    self.assertTrue(dns.queries)
            self.assertFalse(bool(log.exists() and log.read_text()), "mail reached after DNS failure")

    def test_doh_requires_https_and_valid_certificate(self):
        with self.mail_server() as (ports, log):
            self.run_helper("imap", ports, expected=2, MAILBEND_DOH_URL="http://localhost/dns-query")
            for cert in ("wronghost", "expired", "selfsigned"):
                with self.subTest(cert=cert), dns_server(self.certs, cert=cert) as dns:
                    self.run_helper("imap", ports, expected=3, MAILBEND_DOH_URL=dns.url)
                    self.assertEqual(dns.queries, [])
            self.assertFalse(bool(log.exists() and log.read_text()), "mail reached after invalid DoH TLS")

    def test_mail_certificate_still_checked_with_doh_and_ip(self):
        for cert in ("wronghost", "expired", "selfsigned"):
            with self.subTest(cert=cert), self.mail_server(cert=cert) as (ports, log), dns_server(self.certs) as dns:
                for proto in ("imap", "smtp"):
                    self.run_helper(proto, ports, expected=3, MAILBEND_DOH_URL=dns.url)
                    self.run_helper(proto, ports, expected=3, **{f"MAILBEND_{proto.upper()}_CONNECT_IP": "127.0.0.1"})
                lines = log.read_text() if log.exists() else ""
                self.assertFalse("LOGIN" in lines, "IMAP authenticated despite invalid TLS")
                self.assertFalse("AUTH" in lines, "SMTP authenticated despite invalid TLS")


if __name__ == "__main__":
    unittest.main(verbosity=2)
