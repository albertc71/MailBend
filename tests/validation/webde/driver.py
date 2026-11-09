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
    started = time.monotonic()
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
    receipt("command", name=label, exit=code, elapsed_seconds=round(time.monotonic() - started, 6),
            stdout_bytes=len(out), stderr_bytes=len(err),
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

def compiler_identity(root, env, deadline):
    selected = shutil.which("clang", path=env["PATH"])
    if selected is None:
        raise Infrastructure("clang-missing")
    cc = str(Path(selected).resolve(strict=True))
    _, out, err = required([cc, "--version"], root, env, 10, "clang-version", deadline)
    version = re.search(rb"(?:\w+ )?clang version (\d+)", out)
    if version is None or int(version.group(1)) < 14:
        raise Infrastructure("unsupported-clang")
    receipt("compiler", realpath=cc, executable_sha256=digest(Path(cc).read_bytes()),
            version_sha256=digest(out + err))
    return cc

def remove_build_outputs(root):
    for name in ("mailbend-core.c", "mailbend-core"):
        path = root / "bin" / name
        if path.exists():
            path.unlink()

def compile_core(root, env, cc, level, deadline, clean_emission=None):
    if level not in ("O0", "O3"):
        raise Infrastructure("optimization")
    (root / "bin").mkdir(exist_ok=True)
    generated = root / "bin/mailbend-core.c"
    core = root / "bin/mailbend-core"
    remove_build_outputs(root)
    if clean_emission is None:
        required(["bend", "main.bend", "-o", str(generated)], root, env, 300,
                 "emit-c", deadline)
    else:
        code, expected_hash = clean_emission
        if digest(code) != expected_hash:
            raise Infrastructure("retained-emission-drift")
        generated.write_bytes(code)
    code = generated.read_bytes()
    c_hash = digest(code)
    requirements = {
        "nonzero_or_missing_bangs": not bool(re.search(rb"^#define BANGS\s+0$", code, re.M)),
        "objc_directive": bool(re.search(rb"^[ \t]*#import\b", code, re.M)),
        "x11_header": b"#include <X11/" in code,
        "alsa_header": b"#include <alsa/" in code,
    }
    receipt("emission", c_sha256=c_hash, bytes=len(code), optimization=level,
            reused_clean_emission=clean_emission is not None, requirements=requirements,
            provider_sha256=digest((root / "src/providers.bend").read_bytes()))
    if any(requirements.values()):
        raise Infrastructure("unexpected-native-requirements")
    if clean_emission is not None and c_hash != clean_emission[1]:
        raise Infrastructure("restored-emission-drift")
    required([cc, "-std=c11", "-" + level, str(generated), "-lpthread", "-lm",
              "-o", str(core)], root, env, 150 if level == "O3" else 60,
             "compile-native-" + level, deadline)
    if digest(generated.read_bytes()) != c_hash:
        raise Infrastructure("native-input-drift")
    if not core.is_file() or not os.access(core, os.X_OK):
        raise Infrastructure("compiled-core-missing")
    receipt("binary", core_sha256=digest(core.read_bytes()), optimization=level,
            c_sha256=c_hash, launcher_sha256=digest((root / "scripts/mailbend").read_bytes()))
    return c_hash

def bounded_oracle(root, env, deadline, old=False):
    return oracle(root, env, old=old, deadline=min(deadline, time.monotonic() + 30))

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

def unit(root, env, deadline):
    source = root / "tests/unit/providers.bend"
    expected_output = b"".join(line[2:] + b"\n" for line in source.read_bytes().splitlines()
                               if line.startswith(b"#|"))
    code, out, err = command(["bend", "tests/unit/providers.bend"], root, env, 60, "provider-unit", deadline)
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
            or os.environ.get("GITHUB_REF") != "refs/heads/validation/webde-165-residual-20261109"
            or os.environ.get("WEBDE_PRODUCT") != "124dfcda14d270ff25888f0c507eda2d73adc08b"):

        raise Infrastructure("execution-admission")
    lane = os.environ.get("WEBDE_LANE")
    if lane != "mutations":
        raise Infrastructure("lane")
    lane_deadline = time.monotonic() + 1200
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
                     candidate, env, 600, "mcp-comparison-lifecycle", lane_deadline)
            return
        setup_deadline = min(lane_deadline, time.monotonic() + 600)
        cc = compiler_identity(candidate, env, setup_deadline)
        required(["sh", "scripts/install-bend.sh"], baseline, env, 120, "pinned-bend-bootstrap", setup_deadline)
        env["PATH"] = str(home / ".bend/bin") + os.pathsep + env["PATH"]
        required(["bend", "guide"], candidate, env, 30, "pinned-bend-guide", setup_deadline)
        if lane == "focused":
            old = work / "baseline"
            copy_product(baseline, old, "baseline")
            for side, root, is_old in (("candidate", candidate, False), ("baseline", old, True)):
                emissions = []
                for level in ("O3", "O0"):
                    emissions.append(compile_core(root, env, cc, level, lane_deadline))
                    if bounded_oracle(root, env, lane_deadline, old=is_old):
                        raise Infrastructure(side + "-" + level + "-oracle")
                    receipt("qualification", side=side, optimization=level, result="pass")
                if emissions[0] != emissions[1]:
                    raise Infrastructure("optimization-emission-drift")
                unit(root, env, lane_deadline)
            receipt("qualification-complete", modes=["O3", "O0"], sides=["candidate", "baseline"])
            return
        compile_core(candidate, env, cc, "O0", setup_deadline)
        if bounded_oracle(candidate, env, setup_deadline):
            raise Infrastructure("clean-candidate-oracle")
        clean_code = (candidate / "bin/mailbend-core.c").read_bytes()
        clean_emission = (clean_code, digest(clean_code))
        compiler_hash = digest(Path(cc).read_bytes())
        environment_hash = digest(json.dumps(env, sort_keys=True).encode())
        receipt("clean-emission-binding", c_sha256=clean_emission[1],
                inventory_sha256=digest((HERE / "inputs.json").read_bytes()),
                compiler_sha256=compiler_hash, environment_sha256=environment_hash,
                flags=["-std=c11", "-O0", "-lpthread", "-lm"],
                restored_reemission=False, cross_job_reuse=False)
        source = candidate / "src/providers.bend"
        original = source.read_bytes()
        selected = [m for m in MUTATIONS if m["id"] == "global-local-part"]
        if len(selected) != 1 or len(MUTATIONS) != 11:
            raise Infrastructure("residual-selection")
        receipt("partition", selected=["global-local-part"], total_matrix_cases=11,
                prior_run=42610781459, prior_child="907777cab079b0ec239745e8e8f7ae7956ff5d64",
                prior_completed_cases=10, combined_acceptance_pending=True,
                matrix_sha256=digest((HERE / "mutations.json").read_bytes()),
                driver_sha256=digest(Path(__file__).read_bytes()))
        for mutation in selected:
            deadline = min(lane_deadline, time.monotonic() + 540)
            name = mutation["id"]
            before, after = mutation["before"].encode(), mutation["after"].encode()
            if original.count(before) != 1:
                raise Infrastructure("mutation-target-count")
            try:
                changed = original.replace(before, after, 1)
                source.write_bytes(changed)
                receipt("mutation-source", name=name, sha256=digest(changed))
                compile_core(candidate, env, cc, "O0", deadline)
                failures = bounded_oracle(candidate, env, deadline)
                if (EXPECTED_FAILURE[name] not in failures
                        or not failures.issubset(ALLOWED_FAILURES[name])):
                    raise Infrastructure("mutation-not-killed-" + name)
                receipt("mutation-kill", name=name, assertion=EXPECTED_FAILURE[name])
            finally:
                source.write_bytes(original)
                if source.read_bytes() != original:
                    raise Infrastructure("source-restoration")
                remove_build_outputs(candidate)
                verify_export(candidate, "candidate")
            if (digest(Path(cc).read_bytes()) != compiler_hash
                    or digest(json.dumps(env, sort_keys=True).encode()) != environment_hash
                    or digest(clean_code) != clean_emission[1]):
                raise Infrastructure("restored-input-binding")
            compile_core(candidate, env, cc, "O0", deadline, clean_emission=clean_emission)
            if bounded_oracle(candidate, env, deadline):
                raise Infrastructure("restored-control")
            receipt("restored", name=name, source_sha256=digest(original),
                    c_sha256=clean_emission[1], fresh_native_build=True, reemitted=False)
        if set(EXPECTED_FAILURE) != {m["id"] for m in MUTATIONS}:
            raise Infrastructure("mutation-inventory")
        receipt("partition-complete", completed=["global-local-part"],
                full_suite_run=False, prior_run=42610781459)

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
