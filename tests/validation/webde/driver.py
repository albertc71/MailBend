"""Proposed hosted-only evidence driver. No provider connection is required."""
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
INPUTS = json.loads((HERE / "inputs.json").read_text())
MUTATIONS = json.loads((HERE / "mutations.json").read_text())["mutations"]
EXTRAS = {".github/workflows/webde-validation.yml",
          "tests/validation/webde/driver.py", "tests/validation/webde/inputs.json",
          "tests/validation/webde/mutations.json"}
CAP = 1024 * 1024
CANCELLED = False
SECRET = "inherited-synthetic-secret"
FORBIDDEN = ("MAILBEND_APP_PASSWORD", "MAILBEND_CA_FILE", SECRET,
             "stale-inherited-login", "inherited@example.com", "private-trust-marker")
REMOTE = {
    "icloud": ("imap.mail.me.com", "smtp.mail.me.com", "587", "starttls", "1"),
    "gmail": ("imap.gmail.com", "smtp.gmail.com", "465", "implicit", "0"),
    "yahoo": ("imap.mail.yahoo.com", "smtp.mail.yahoo.com", "465", "implicit", "0"),
    "aol": ("imap.aol.com", "smtp.aol.com", "465", "implicit", "0"),
    "fastmail": ("imap.fastmail.com", "smtp.fastmail.com", "465", "implicit", "0"),
    "zoho": ("imap.zoho.com", "smtp.zoho.com", "465", "implicit", "0"),
    "gmx": ("imap.gmx.com", "mail.gmx.com", "465", "implicit", "0"),
    "mailbox.org": ("imap.mailbox.org", "smtp.mailbox.org", "465", "implicit", "0"),
    "posteo": ("posteo.de", "posteo.de", "465", "implicit", "0"),
}
EXPECTED_FAILURE = {
    "empty-login": "webde-json",
    "full-address-login": "webde-json",
    "lowercase-local": "webde-json",
    "missing-domain-guard": "domain-example",
    "suffix-domain-guard": "domain-sub",
    "substring-domain-guard": "domain-suffix",
    "case-sensitive-domain": "uppercase-json",
    "wrong-smtp-port": "webde-json",
    "wrong-imap-host": "webde-json",
    "unquoted-shell-values": "quoted-shell",
    "global-local-part": "gmail-json",
}
WEB_FAILURES = {name + suffix for name in ("webde", "uppercase", "quoted")
                for suffix in ("-json", "-shell")}
ALLOWED_FAILURES = {
    **{name: WEB_FAILURES for name in
       ("empty-login", "full-address-login", "lowercase-local", "wrong-smtp-port", "wrong-imap-host")},
    "missing-domain-guard": {"domain-example", "domain-sub", "domain-suffix",
                             "domain-trailing", "domain-prefix"},
    "suffix-domain-guard": {"domain-sub", "domain-prefix"},
    "substring-domain-guard": {"domain-sub", "domain-suffix", "domain-trailing", "domain-prefix"},
    "case-sensitive-domain": {"uppercase-json", "uppercase-shell"},
    "unquoted-shell-values": {"quoted-shell", "quoted-injection"},
    "global-local-part": {name + suffix for name in (*REMOTE, "gmail-webde-email")
                         for suffix in ("-json", "-shell")},
}

class Infrastructure(Exception):
    pass

def digest(data):
    return hashlib.sha256(data).hexdigest()

def receipt(kind, **fields):
    line = json.dumps({"kind": kind, **fields}, sort_keys=True)
    if len(line.encode()) > CAP:
        raise Infrastructure("receipt-cap")
    print(line, flush=True)

def command(argv, cwd, env, seconds, label, deadline=None):
    if CANCELLED:
        raise Infrastructure("interrupted")
    if deadline is not None:
        seconds = min(seconds, deadline - time.monotonic())
    if seconds <= 0:
        raise Infrastructure(label + "-deadline")
    process = None
    selector = None
    buffers = {"out": bytearray(), "err": bytearray()}
    failed = None
    code = None
    try:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        selector = selectors.DefaultSelector()
        for stream, name in ((process.stdout, "out"), (process.stderr, "err")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        end = time.monotonic() + seconds
        if deadline is not None:
            end = min(end, deadline)
        while selector.get_map():
            if CANCELLED:
                raise Infrastructure("interrupted")
            if time.monotonic() >= end:
                raise Infrastructure(label + "-timeout")
            for key, _ in selector.select(min(.1, max(0, end - time.monotonic()))):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buffers[key.data].extend(chunk)
                if sum(map(len, buffers.values())) > CAP:
                    raise Infrastructure(label + "-output-cap")
        while os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
            if CANCELLED:
                raise Infrastructure("interrupted")
            if time.monotonic() >= end:
                raise Infrastructure(label + "-timeout")
            time.sleep(.02)
    except BaseException as error:
        failed = error
    finally:
        try:
            if selector is not None:
                selector.close()
        finally:
            if process is not None:
                try:
                    for sig in (signal.SIGTERM, signal.SIGKILL):
                        try:
                            os.killpg(process.pid, sig)
                        except ProcessLookupError:
                            pass
                    try:
                        code = process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        raise Infrastructure(label + "-cleanup-timeout") from None
                finally:
                    for stream in (process.stdout, process.stderr):
                        if stream is not None:
                            stream.close()
    out, err = bytes(buffers["out"]), bytes(buffers["err"])
    receipt("command", name=label, exit=code, stdout_bytes=len(out), stderr_bytes=len(err),
            stdout_sha256=digest(out), stderr_sha256=digest(err))
    if failed:
        raise failed
    if CANCELLED:
        raise Infrastructure("interrupted")
    return code, out, err

def required(argv, cwd, env, seconds, label, deadline=None):
    result = command(argv, cwd, env, seconds, label, deadline)
    if result[0] != 0:
        raise Infrastructure(label + "-nonzero")
    return result

def source_bytes(path):
    return os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()

def verify_export(root, label, allow_extras=False):
    expected = INPUTS["trees"][label]["files"]
    found = set()
    for base, dirs, files in os.walk(root, followlinks=False):
        if Path(base) == root and ".git" in dirs:
            dirs.remove(".git")
        for name in list(dirs):
            if (Path(base) / name).is_symlink():
                dirs.remove(name)
                files.append(name)
        for name in files:
            relative = (Path(base) / name).relative_to(root).as_posix()
            if relative == ".git":
                continue
            found.add(relative)
    if found != set(expected) | (EXTRAS if allow_extras else set()):
        raise Infrastructure(label + "-path-inventory")
    for relative, row in expected.items():
        path = root / relative
        mode = "120000" if path.is_symlink() else "100755" if path.stat().st_mode & 0o111 else "100644"
        if mode != row["mode"] or digest(source_bytes(path)) != row["sha256"]:
            raise Infrastructure(label + "-source-identity")
    receipt("source", side=label, entries=len(expected), tree=INPUTS["trees"][label]["tree_sha"])

def copy_product(source, target, label):
    for relative in INPUTS["trees"][label]["files"]:
        src, dst = source / relative, target / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        if src.is_symlink():
            dst.symlink_to(os.readlink(src))
        else:
            shutil.copy2(src, dst)
    verify_export(target, label)

def compile_core(root, env, deadline=None):
    (root / "bin").mkdir(exist_ok=True)
    required(["bend", "main.bend", "-o", "bin/mailbend-core"], root, env, 120,
             "compile-core", deadline)
    core = root / "bin/mailbend-core"
    if not core.is_file() or not os.access(core, os.X_OK):
        raise Infrastructure("compiled-core-missing")
    receipt("binary", core_sha256=digest(core.read_bytes()),
            launcher_sha256=digest((root / "scripts/mailbend").read_bytes()))

def expected(email, login, endpoint):
    imap, smtp, port, tls, sent = endpoint
    return {"MAILBEND_EMAIL": email, "MAILBEND_LOGIN": login,
            "MAILBEND_PASSWORD_FILE": "/absolute/path/to/mailbend-password",
            "MAILBEND_IMAP_HOST": imap, "MAILBEND_IMAP_PORT": "993",
            "MAILBEND_SMTP_HOST": smtp, "MAILBEND_SMTP_PORT": port,
            "MAILBEND_SMTP_TLS_MODE": tls, "MAILBEND_READ_ONLY": "1",
            "MAILBEND_SAVE_SENT": sent}

def oracle(root, env, old=False, deadline=None):
    failures = set()
    def observe(name, okay):
        if not okay:
            failures.add(name)
    with tempfile.TemporaryDirectory(prefix="offline-", dir=env["TMPDIR"]) as directory:
        work = Path(directory)
        fifo, marker, helper = work / "password-fifo", work / "helper-called", work / "tripwire"
        os.mkfifo(fifo, 0o600)
        helper.write_text("#!/bin/sh\nprintf called > ./helper-called\nexit 99\n")
        helper.chmod(0o700)
        initial = sorted(p.name for p in work.iterdir())
        inherited = {**env, "MAILBEND_PASSWORD_FILE": str(fifo),
                     "MAILBEND_APP_PASSWORD": SECRET, "MAILBEND_LOGIN": "stale-inherited-login",
                     "MAILBEND_EMAIL": "inherited@example.com", "MAILBEND_READ_ONLY": "invalid",
                     "MAILBEND_TYPESAFE": "invalid", "MAILBEND_CA_FILE": "private-trust-marker",
                     "SSL_CERT_FILE": "private-trust-marker", "SSL_CERT_DIR": "",
                     **{k: str(helper) for k in ("MAILBEND_TLS_HELPER", "MAILBEND_ATTACH_HELPER",
                                               "MAILBEND_TYPESAFE_HELPER")}}
        launcher = str(root / "scripts/mailbend")
        def invoke(args, check_variable_names=True):
            code, out, err = command([launcher, "setup", *args], work, inherited, 10, "setup", deadline)
            if code not in (0, 2):
                raise Infrastructure("setup-unexpected-exit")
            text = (out + err).decode("utf-8", errors="strict")
            forbidden = FORBIDDEN if check_variable_names else FORBIDDEN[2:]
            observe("no-secret-output", not any(x in text for x in forbidden))
            return code, out, err
        def success(name, provider, email, login, endpoint):
            code, out, err = invoke(["--provider", provider, "--email", email])
            target = expected(email, login, endpoint)
            block = re.search(rb"```json\n(.*?)\n```", out, re.S)
            try:
                config = json.loads(block[1])["env"] if block else None
            except (ValueError, KeyError, TypeError):
                config = None
            observe(name + "-json", code == 0 and not err and config == target)
            shell = re.search(rb"```sh\n(.*?)```", out, re.S)
            if not shell:
                observe(name + "-shell", False)
                return
            script = shell[1].decode() + "\npython3 -c 'import os,json; print(json.dumps({k:v for k,v in os.environ.items() if k.startswith(\"MAILBEND_\")}))'\n"
            with tempfile.TemporaryDirectory(prefix="shell-", dir=work) as shell_directory:
                shell_work = Path(shell_directory)
                status, values, shell_err = command(["sh", "-c", script], shell_work,
                    {**env, "MAILBEND_LOGIN": "stale-inherited-login"}, 10, name + "-shell", deadline)
                try:
                    decoded = json.loads(values)
                except (ValueError, UnicodeError):
                    decoded = None
                created = {p.name for p in shell_work.iterdir()}
                observe(name + "-injection", "shell-injection" not in created)
                observe(name + "-unexpected-files", not (created - {"shell-injection"}))
                observe(name + "-shell", status == 0 and not shell_err and decoded == target
                        and not created)
        def refusal(name, provider, email):
            code, out, err = invoke(["--provider", provider, "--email", email])
            observe(name, code == 2 and not out and b"```" not in err)
        web = ("imap.web.de", "smtp.web.de", "465", "implicit", "0")
        if old:
            refusal("baseline-webde-manual", "web.de", "Reader.Name@web.de")
        else:
            success("webde", "web.de", "Reader.Name@web.de", "Reader.Name", web)
            success("uppercase", "WEB.DE", "Reader.Name@WEB.DE", "Reader.Name", web)
            success("quoted", "web.de", "o'hara+$`touch${IFS}shell-injection`@web.de",
                    "o'hara+$`touch${IFS}shell-injection`", web)
        for provider, endpoint in REMOTE.items():
            success(provider, provider, "reader@example.com", "", endpoint)
        success("gmail-webde-email", "gmail", "Reader.Name@web.de", "", REMOTE["gmail"])
        for name, email in (("domain-example", "reader@example.com"), ("domain-sub", "reader@sub.web.de"),
                            ("domain-suffix", "reader@web.de.example"), ("domain-trailing", "reader@web.de."),
                            ("domain-prefix", "reader@notweb.de")):
            refusal(name, "web.de", email)
        for email in ("@web.de", "reader@", "reader@@web.de", " reader@web.de", "reader@web.de ",
                      "Name <reader@web.de>", "reader@web.de (comment)", "reader@web.de\n",
                      "reader@web.de\r", "a\x1b@web.de", "é@web.de", "a" * 248 + "@web.de"):
            refusal("malformed-address", "web.de", email)
        for provider in ("unknown", "outlook", "hotmail", "office365", "proton-bridge"):
            refusal("refused-" + provider, provider, "reader@example.com")
        for args in ([], ["--provider", "web.de"],
                     ["--provider", "web.de", "--email", "Reader.Name@web.de", "--check"],
                     ["--provider", "web.de", "--email", "Reader.Name@web.de", "--unknown"]):
            code, out, err = invoke(args, check_variable_names=False)
            observe("argument-grammar", code == 2 and not out)
        observe("no-helper-invocation", not marker.exists())
        observe("no-file-effects", sorted(p.name for p in work.iterdir()) == initial)
    receipt("oracle", baseline=old, failures=sorted(failures))
    return failures

def unit(root, env):
    source = root / "tests/unit/providers.bend"
    expected_output = b"".join(line[2:] + b"\n" for line in source.read_bytes().splitlines()
                               if line.startswith(b"#|"))
    code, out, err = command(["bend", "tests/unit/providers.bend"], root, env, 120, "provider-unit")
    if code != 0 or err or out != expected_output:
        diagnostic = (out + b"\n" + err)[:4096].decode("utf-8", errors="replace")
        diagnostic = "".join(c if c in "\n\t" or 32 <= ord(c) < 127 else "?" for c in diagnostic)
        diagnostic = diagnostic.replace(SECRET, "[synthetic secret omitted]")
        receipt("unit-diagnostic", exit=code, text=diagnostic,
                truncated=len(out) + 1 + len(err) > 4096)
        raise Infrastructure("provider-unit-literal-output")
    receipt("unit", result="pass", oracle_sha256=digest(expected_output))

def main():
    if (os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("WEBDE_RUN_ATTEMPT") != "1"
            or not re.fullmatch("[0-9a-f]{40}", os.environ.get("WEBDE_HEAD", ""))
            or os.environ.get("GITHUB_EVENT_NAME") != "push"
            or os.environ.get("GITHUB_REF") != "refs/heads/validation/webde-165-current-20261109"
            or os.environ.get("WEBDE_PRODUCT") != "124dfcda14d270ff25888f0c507eda2d73adc08b"):

        raise Infrastructure("execution-admission")
    lane = os.environ.get("WEBDE_LANE")
    if lane not in ("focused", "mutations", "supplemental"):
        raise Infrastructure("lane")
    checkout = HERE.parents[2]
    baseline = checkout.parent / "baseline"
    verify_export(checkout, "candidate", allow_extras=True)
    verify_export(baseline, "baseline")
    with tempfile.TemporaryDirectory(prefix="webde-validation-", dir=os.environ["RUNNER_TEMP"]) as temporary:
        work = Path(temporary)
        home, tmp = work / "home", work / "tmp"
        home.mkdir()
        tmp.mkdir()
        env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(tmp),
               "LANG": "C.UTF-8", "BEND_NO_TELEMETRY": "1", "PYTHONDONTWRITEBYTECODE": "1"}
        candidate = work / "candidate"
        copy_product(checkout, candidate, "candidate")
        if lane == "supplemental":
            required([sys.executable, "tests/test-mcp-schema-comparison.py"],
                     candidate, env, 600, "mcp-comparison-lifecycle")
            return
        if shutil.which("clang", path=env["PATH"]) is None:
            raise Infrastructure("clang-missing")
        required(["sh", "scripts/install-bend.sh"], baseline, env, 300, "pinned-bend-bootstrap")
        env["PATH"] = str(home / ".bend/bin") + os.pathsep + env["PATH"]
        required(["bend", "guide"], candidate, env, 30, "pinned-bend-guide")
        compile_core(candidate, env)
        if oracle(candidate, env):
            raise Infrastructure("clean-candidate-oracle")
        if lane == "focused":
            unit(candidate, env)
            old = work / "baseline"
            copy_product(baseline, old, "baseline")
            compile_core(old, env)
            unit(old, env)
            if oracle(old, env, old=True):
                raise Infrastructure("baseline-control")
            return
        source = candidate / "src/providers.bend"
        original = source.read_bytes()
        for mutation in MUTATIONS:
            deadline = time.monotonic() + 180
            name = mutation["id"]
            before, after = mutation["before"].encode(), mutation["after"].encode()
            if original.count(before) != 1:
                raise Infrastructure("mutation-target-count")
            try:
                changed = original.replace(before, after, 1)
                source.write_bytes(changed)
                receipt("mutation-source", name=name, sha256=digest(changed))
                compile_core(candidate, env, deadline)
                failures = oracle(candidate, env, deadline=deadline)
                if (EXPECTED_FAILURE[name] not in failures
                        or not failures.issubset(ALLOWED_FAILURES[name])):
                    raise Infrastructure("mutation-not-killed-" + name)
                receipt("mutation-kill", name=name, assertion=EXPECTED_FAILURE[name])
            finally:
                source.write_bytes(original)
                if source.read_bytes() != original:
                    raise Infrastructure("source-restoration")
            compile_core(candidate, env, deadline)
            if oracle(candidate, env, deadline=deadline):
                raise Infrastructure("restored-control")
            receipt("restored", name=name, source_sha256=digest(original))
        if set(EXPECTED_FAILURE) != {m["id"] for m in MUTATIONS}:
            raise Infrastructure("mutation-inventory")

if __name__ == "__main__":
    def interrupted(signum, frame):
        global CANCELLED
        CANCELLED = True
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        main()
    except BaseException as error:
        code = str(error) if isinstance(error, Infrastructure) else type(error).__name__
        receipt("result", status="incomplete-or-failed", reason=code)
        sys.exit(1)
    receipt("result", status="pass")
