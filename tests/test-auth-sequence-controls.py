"""Negative controls for the LOGIN fixture, with a synthetic Python client only."""
import argparse
import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tempfile


CLIENT = r'''#!{python}
import os
import socket
import ssl
import sys
import time

reason = {reason!r}
context = ssl.create_default_context(cafile=os.environ['MAILBEND_CA_FILE'])
with socket.create_connection(('127.0.0.1', int(os.environ['MAILBEND_IMAP_PORT'])), 5) as raw:
    with context.wrap_socket(raw, server_hostname='127.0.0.1') as wire:
        def line():
            result = b''
            while not result.endswith(b'\n'):
                block = wire.recv(1)
                if not block:
                    raise RuntimeError('synthetic server closed early')
                result += block
            return result
        assert line().startswith(b'* OK ')
        wire.sendall(b'L LOGIN "synthetic" "synthetic"\r\n')
        assert line().startswith(b'* BYE ')
        if reason is not None:
            assert line().startswith(b'* BYE ')
        time.sleep(0.1)
        wire.sendall({extra!r})
        time.sleep(0.05)
if sys.argv[1] == 'imap':
    sys.stderr.write({stderr!r})
    sys.exit(6)
print({diagnostic!r})
'''

CASES = ('conflicting-close', 'silence', 'stream-lines', 'stream-byes', 'drip-line',
         'fragmented-record', 'drip-literal', 'zero-literals')


def certificates(path):
    def openssl(*args):
        subprocess.run(['openssl', *args], cwd=path, check=True, capture_output=True,
                       timeout=10, umask=0o077)

    openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
            '-keyout', 'ca-key.pem', '-out', 'ca.pem', '-subj', '/CN=MailBend Observer CA',
            '-addext', 'basicConstraints=critical,CA:TRUE',
            '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
    openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', 'ip-address-key.pem', '-out', 'server.csr',
            '-subj', '/CN=MailBend Observer')
    (path / 'server.ext').write_text(
        'subjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\n'
        'keyUsage=critical,digitalSignature,keyEncipherment\n'
        'extendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\n'
        'authorityKeyIdentifier=keyid,issuer\n')
    openssl('x509', '-req', '-in', 'server.csr', '-CA', 'ca.pem',
            '-CAkey', 'ca-key.pem', '-CAcreateserial', '-days', '2',
            '-extfile', 'server.ext', '-out', 'ip-address.pem')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', type=pathlib.Path)
    parser.add_argument('--driver', type=pathlib.Path,
                        default=pathlib.Path(__file__).with_name('auth_sequence_controls.py'))
    parser.add_argument('--case', choices=CASES, action='append')
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('auth_sequences', args.driver)
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    fixture = json.loads(args.fixture.read_text())
    failures = 0
    with tempfile.TemporaryDirectory(prefix='mailbend-auth-observer-') as temp:
        certs = pathlib.Path(temp)
        certificates(certs)
        helper = certs / 'synthetic-client'
        for name in args.case or CASES:
            reason = 'temporary' if name == 'conflicting-close' else None
            for mode in ('imap', 'diagnose-imap'):
                for label, extra, marker in (
                        ('quiet', b'', None),
                        ('extra-command', b'a1 NOOP\r\n', 'NOOP'),
                        ('partial-command', b'a2 FETCH private-command-marker',
                         'partial-application')):
                    helper.write_text(CLIENT.format(
                        python=sys.executable, extra=extra, reason=reason,
                        stderr='mailbend-auth: temporary\n' if reason else
                               'read from server timed out\n',
                        diagnostic='authentication ' + (reason or 'failed')))
                    helper.chmod(0o700)
                    captured = io.StringIO()
                    with contextlib.redirect_stdout(captured):
                        accepted = driver.run_case(helper, certs, fixture,
                                                   name, 6, reason, mode)
                    report = captured.getvalue()
                    outcome_ok = ('classification=True' in report and 'redacted=True' in report
                                  and 'fixture_errors=[]' in report and 'record=True' in report)
                    observed = marker is None or marker in report
                    safe_report = 'private-command-marker' not in report
                    passed = outcome_ok and observed and safe_report and accepted == (not extra)
                    failures += not passed
                    print(f'{"PASS" if passed else "FAIL"} observer {name} {mode} {label}: '
                          f'outcome={outcome_ok} observed={observed} sanitized={safe_report} '
                          f'accepted={accepted}')
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
