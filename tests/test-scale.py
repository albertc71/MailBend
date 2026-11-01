#!/usr/bin/env python3
"""Measure compiled public calls against local synthetic servers. Linux only."""
import argparse
from email import policy
from email.parser import BytesParser
import hashlib
import json
import math
import os
import pathlib
import platform
import resource
import selectors
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import traceback

from scale_fixtures import PASSWORD, SCENARIOS, USER, fixture

ROOT = pathlib.Path(__file__).resolve().parents[1]
KEY = "synthetic-scale-typesafe-key"
METRICS = ("wall_seconds", "peak_rss_kib", "imap_logins")
LIMIT_SECONDS = 900
CALL_SECONDS = 90
RSS_LIMIT_KIB = 3 * 1024 ** 2
POLL_SECONDS = 0.01
REPEATS = 5


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clean_env(home):
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home),
            "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "BEND_NO_TELEMETRY": "1"}


def child_limits():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_FSIZE, (128 * 1024 ** 2, 128 * 1024 ** 2))


def server_limits():
    resource.setrlimit(resource.RLIMIT_AS, (1536 * 1024 ** 2, 1536 * 1024 ** 2))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


def group_snapshot(pid):
    total, primary, scanned = 0, False, 0
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        scanned += 1
        try:
            text = (entry / "stat").read_text()
            fields = text[text.rindex(")") + 2:].split()
            if int(fields[2]) == pid:
                total += max(0, int(fields[21])) * os.sysconf("SC_PAGE_SIZE") // 1024
                primary |= int(entry.name) == pid
        except (OSError, ValueError, IndexError):
            continue
    return {"rss_kib": total if primary else None, "processes_scanned": scanned}


def measure(command, env, work, timeout):
    """A fresh GNU time supervisor excludes the fixture parent from child RSS."""
    timer = shutil.which("time", path=env["PATH"])
    if not timer:
        raise RuntimeError("GNU time is required")
    usage_path = work / "resource-usage"
    usage_path.unlink(missing_ok=True)
    command = [timer, "-q", "-f", "%M %U %S", "-o", str(usage_path), "--", *command]
    with (work / "stdout").open("wb") as out, (work / "stderr").open("wb") as err:
        start = time.perf_counter()
        own_start = resource.getrusage(resource.RUSAGE_SELF)
        proc = subprocess.Popen(command, env=env, stdout=out, stderr=err,
                                start_new_session=True, preexec_fn=child_limits)
        timed_out = False
        memory_stop = None
        sampled_peak = 0
        scanned_peak = 0
        try:
            while True:
                pid, status, usage = os.wait4(proc.pid, os.WNOHANG)
                if pid:
                    proc.returncode = os.waitstatus_to_exitcode(status)
                    break
                snapshot = group_snapshot(proc.pid)
                rss = snapshot["rss_kib"]
                scanned_peak = max(scanned_peak, snapshot["processes_scanned"])
                if rss is None:
                    pid, status, usage = os.wait4(proc.pid, os.WNOHANG)
                    if pid:
                        proc.returncode = os.waitstatus_to_exitcode(status)
                        break
                    memory_stop = "process RSS is not observable"
                else:
                    sampled_peak = max(sampled_peak, rss)
                    if rss > RSS_LIMIT_KIB:
                        memory_stop = "sampled process-group RSS exceeds safety threshold"
                if time.perf_counter() - start >= timeout or memory_stop:
                    os.killpg(proc.pid, signal.SIGKILL)
                    _, status, usage = os.wait4(proc.pid, 0)
                    proc.returncode = os.waitstatus_to_exitcode(status)
                    timed_out = memory_stop is None
                    break
                time.sleep(POLL_SECONDS)
        finally:
            if proc.returncode is None:
                kill_group(proc)
    measured = None
    if usage_path.exists():
        fields = usage_path.read_text().strip().split()
        if len(fields) == 3 and fields[0].isdigit():
            values = [float(value) for value in fields]
            if all(math.isfinite(value) and value >= 0 for value in values):
                measured = values
    if proc.returncode == 0 and (measured is None or measured[0] <= 0):
        raise RuntimeError("GNU time did not produce valid resource measurements")
    own_end = resource.getrusage(resource.RUSAGE_SELF)
    return {"wall_seconds": time.perf_counter() - start,
            "peak_rss_kib": int(measured[0]) if measured else None,
            "user_seconds": measured[1] if measured else None,
            "system_seconds": measured[2] if measured else None,
            "exit_code": proc.returncode, "timed_out": timed_out,
            "memory_stop": memory_stop, "sampled_group_peak_rss_kib": sampled_peak,
            "supervisor_cpu_seconds": own_end.ru_utime + own_end.ru_stime - own_start.ru_utime - own_start.ru_stime,
            "max_processes_scanned": scanned_peak}


class Server:
    def __init__(self, command, env, work, label, timeout):
        self.err = (work / f"{label}-stderr").open("wb")
        self.proc = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                                     stderr=self.err, start_new_session=True, preexec_fn=server_limits)
        try:
            deadline = time.monotonic() + timeout
            ready = b""
            with selectors.DefaultSelector() as selector:
                selector.register(self.proc.stdout, selectors.EVENT_READ)
                while b"\n" not in ready:
                    if not selector.select(max(0, deadline - time.monotonic())):
                        raise RuntimeError(f"{label} startup timed out")
                    chunk = os.read(self.proc.stdout.fileno(), 1024)
                    if not chunk or len(ready) + len(chunk) > 4096:
                        raise RuntimeError(f"{label} invalid readiness response")
                    ready += chunk
                line = ready.decode("ascii").strip().split()
            if not line or line[0] != "READY":
                raise RuntimeError(f"{label} did not become ready")
            self.ports = dict(item.split("=") for item in line[1:])
        except BaseException:
            self.stop()
            raise

    def stop(self):
        if self.proc.poll() is None:
            kill_group(self.proc)
        self.proc.stdout.close()
        self.err.close()


def certificates(work, env):
    certs = work / "certs"
    certs.mkdir()

    def openssl(*args):
        subprocess.run(["openssl", *map(str, args)], check=True, env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=15)

    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
            "-keyout", certs / "ca-key.pem", "-out", certs / "ca.pem", "-subj", "/CN=Scale test CA")
    for name, san in (("server", "DNS:localhost"), ("typesafe", "DNS:api.typesafe.ai")):
        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", certs / f"{name}-key.pem",
                "-out", certs / f"{name}.csr", "-subj", f"/CN={name}")
        ext = certs / f"{name}.ext"
        ext.write_text(f"subjectAltName={san}\n")
        openssl("x509", "-req", "-in", certs / f"{name}.csr", "-CA", certs / "ca.pem",
                "-CAkey", certs / "ca-key.pem", "-CAcreateserial", "-days", "2",
                "-out", certs / f"{name}.pem", "-extfile", ext)
    (certs / "ca-key.pem").unlink()
    return certs


def records(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def verify(scenario, data, result, logged, state, requests):
    if "error" in result or result.get("partial"):
        raise ValueError("tool returned an error or partial outcome")
    lines = [row["line"] for row in logged if row["proto"] == "imap"]
    if scenario.kind != "forward" and any(
            any(word in line for word in (" SELECT ", " STORE ", " APPEND ", " EXPUNGE",
                                         " COPY ", " MOVE ", " CREATE ", " DELETE ", " RENAME ",
                                         " SUBSCRIBE ", " UNSUBSCRIBE "))
            or ("BODY[" in line and "FETCH" in line) for line in lines):
        raise ValueError("read issued a mutating command")
    if scenario.kind != "forward" and state["mailboxes"] != {
            name: {**box, "special": box.get("special", []),
                   "uidnext": max((m["uid"] for m in box["messages"]), default=0) + 1}
            for name, box in data["mailboxes"].items()}:
        raise ValueError("read changed mailbox state")
    if scenario.kind != "forward" and (state["sent"] or state["subscribed"]
                                       or any(r["proto"] == "smtp" for r in logged)):
        raise ValueError("read reached SMTP")
    if scenario.kind == "search":
        assert result["total"] == scenario.count
        assert [m["uid"] for m in result["messages"]] == list(range(scenario.count, scenario.count - 200, -1))
        assert result["has_more"] is True and result["next_cursor"]
    elif scenario.kind == "folders":
        assert len(result["folders"]) == scenario.count
        assert {m["name"] for m in result["folders"]} == set(data["mailboxes"])
    elif scenario.kind == "read":
        original = data["mailboxes"]["INBOX"]["messages"][0]["raw"]
        expected = original.split("\r\n\r\n", 1)[1]
        assert result["size"] == scenario.count
        assert result["truncated"] is False
        assert result["text"].replace("\r\n", "\n") == expected.replace("\r\n", "\n")
        assert any(row["proto"] == "imap-section-bytes" and row["line"].endswith(f" {scenario.count}")
                   for row in logged)
    elif scenario.kind == "forward":
        original = data["mailboxes"]["INBOX"]["messages"][0]["raw"]
        assert result["sent_copy"] == "saved to Sent"
        assert len(state["sent"]) == 1 and len(state["mailboxes"]["Sent"]["messages"]) == 1
        delivered = state["sent"][0]["data"]
        parsed = BytesParser(policy=policy.SMTP).parsebytes(delivered.encode("ascii"))
        attached = [part for part in parsed.walk() if part.get_filename() == "forwarded-message.eml"]
        assert len(attached) == 1 and attached[0].get_content_type() == "message/rfc822"
        assert attached[0]["Content-Transfer-Encoding"] == "7bit"
        assert attached[0].get_payload()[0].as_bytes(policy=policy.SMTP) == original.encode("ascii")
        assert state["mailboxes"]["Sent"]["messages"][0]["raw"] == delivered
        assert state["sent"][0]["rcpt_to"] == ["recipient@example.com"]
        assert state["mailboxes"]["INBOX"]["messages"] == data["mailboxes"]["INBOX"]["messages"]
    elif scenario.kind == "thread":
        assert len(result["messages"]) == scenario.count
        assert {(m["folder"], m["uid"]) for m in result["messages"]} == {
            ("INBOX", i) for i in range(1, scenario.count + 1)}
    else:
        assert {m["uid"] for m in result["messages"]} == set(range(1, 51))
        assert not result["not_found"]
        images = [image for m in result["messages"] for image in m.get("images", [])]
        assert len(images) == 50 and all(len(m.get("images", [])) == 1 for m in result["messages"])
        assert all(i["fate"] == "used" or (i["fate"] == "skipped" and i["reason"] == "over_count")
                   for i in images)
        image_uses = sum(image["fate"] == "used" for image in images)
        answered = [r for r in requests if "status" in r]
        assert image_uses > 0 and answered and all(r["status"] == 200 for r in answered)
        assert sum(len(r["body"].get("assets", {})) for r in answered) == image_uses
        assert all(len(r["body"].get("assets", {})) == min(4, len(r["body"]["state"]["emails"]))
                   for r in answered)
        assert sorted(m["uid"] for r in answered for m in r["body"]["state"]["emails"]) == list(range(1, 51))
    return {"fixture_count": scenario.count,
            "body_bytes_fetched": sum(int(r["line"].rsplit(" ", 1)[1])
                                      for r in logged if r["proto"] == "imap-section-bytes"),
            "smtp_messages": len(state["sent"]),
            "typesafe_requests": sum("status" in r for r in requests)}


def run_sample(scenario, work, certs, deadline):
    data = fixture(scenario)
    fixture_path = work / "fixture.json"
    fixture_path.write_text(json.dumps(data))
    env = clean_env(work)
    servers = []
    try:
        server = Server([sys.executable, str(ROOT / "tests/fake_mail_server.py"),
                         "--certdir", str(certs), "--fixture", str(fixture_path),
                         "--state", str(work / "state.json"), "--log", str(work / "mail.jsonl")],
                        env, work, "mail", min(30, max(1, deadline - time.monotonic())))
        servers.append(server)
        call_env = {**env, "MAILBEND_EMAIL": USER, "MAILBEND_APP_PASSWORD": PASSWORD,
                    "MAILBEND_IMAP_HOST": "localhost", "MAILBEND_IMAP_PORT": server.ports["imap"],
                    "MAILBEND_SMTP_HOST": "localhost", "MAILBEND_SMTP_PORT": server.ports["smtp"],
                    "MAILBEND_CA_FILE": str(certs / "ca.pem"), "MAILBEND_TIMEOUT_MS": "60000",
                    "MAILBEND_TYPESAFE": "0", "MAILBEND_SENT_FOLDER": "Sent"}
        if scenario.kind == "forward":
            call_env["MAILBEND_SAVE_SENT"] = "1"
        if scenario.kind == "classify":
            ts = Server([sys.executable, str(ROOT / "tests/fake_typesafe.py"), "--certdir", str(certs),
                         "--key", KEY, "--log", str(work / "typesafe.jsonl")], env, work, "typesafe", 10)
            servers.append(ts)
            keyfile = work / "key"
            keyfile.write_text(KEY)
            keyfile.chmod(0o600)
            call_env.update({"MAILBEND_TYPESAFE": "1", "MAILBEND_TYPESAFE_KEY_FILE": str(keyfile),
                             "MAILBEND_TYPESAFE_CONTENT": "body", "MAILBEND_TYPESAFE_IMAGES": "1",
                             "MAILBEND_TYPESAFE_ZERO_RETENTION": "1",
                             "https_proxy": f"http://127.0.0.1:{ts.ports['proxy']}"})
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("suite deadline reached before call")
        sample = measure([str(ROOT / "scripts/mailbend"), "call", scenario.tool,
                          json.dumps(scenario.arguments)], call_env, work, min(CALL_SECONDS, remaining))
        logged = records(work / "mail.jsonl")
        sample["imap_logins"] = sum(row["proto"] == "imap" and
                                    (" LOGIN " in row["line"] or "AUTHENTICATE" in row["line"])
                                    for row in logged)
        sample["status"] = "failed"
        if sample["timed_out"] or sample["exit_code"] != 0:
            sample["reason"] = (sample["memory_stop"] or
                                ("timeout" if sample["timed_out"] else "nonzero tool exit"))
            diagnostic = (work / "stderr").read_bytes()[:2048].decode("utf-8", "replace")
            sample["diagnostic"] = diagnostic.replace(PASSWORD, "<redacted>").replace(KEY, "<redacted>")
            return sample
        output = (work / "stdout").read_text()
        errors = (work / "stderr").read_text()
        if PASSWORD in output + errors or KEY in output + errors:
            raise ValueError("synthetic credential leaked")
        result = json.loads(output)
        sample["work"] = verify(scenario, data, result, logged,
                                json.loads((work / "state.json").read_text()),
                                records(work / "typesafe.jsonl"))
        sample["status"] = "passed"
        return sample
    finally:
        for server in reversed(servers):
            server.stop()


def profile():
    info = pathlib.Path("/proc/cpuinfo").read_text()
    model = next((line.split(":", 1)[1].strip() for line in info.splitlines()
                  if line.startswith("model name")), "unknown")
    version = subprocess.check_output(["bend", "version"], text=True, timeout=10).strip()
    return {"runner": os.environ.get("RUNNER_ENVIRONMENT", "local"),
            "os": platform.freedesktop_os_release().get("PRETTY_NAME", platform.system()),
            "arch": platform.machine(), "cpu": model, "logical_cpus": os.cpu_count(),
            "bend": version, "rss_semantics": "gnu-time-child-max-process-kib-not-tree-sum",
            "gnu_time_sha256": digest(pathlib.Path(shutil.which("time"))),
            "gnu_time_version": subprocess.check_output(["time", "--version"], text=True, timeout=10).splitlines()[0],
            "sampled_group_rss_limit_kib": RSS_LIMIT_KIB, "poll_seconds": POLL_SECONDS,
            "call_limit_seconds": CALL_SECONDS,
            "repeats": REPEATS,
            "fixture_generator_sha256": digest(ROOT / "tests/scale_fixtures.py"),
            "measurement_sha256": digest(pathlib.Path(__file__))}


def valid_sample(sample):
    return (isinstance(sample, dict) and sample.get("status") == "passed"
            and type(sample.get("exit_code")) is int and sample["exit_code"] == 0
            and sample.get("timed_out") is False
            and sample.get("memory_stop") is None
            and isinstance(sample.get("work"), dict)
            and all(type(sample["work"].get(key)) is int and sample["work"][key] >= 0
                    for key in ("fixture_count", "body_bytes_fetched", "smtp_messages", "typesafe_requests"))
            and sample["work"]["fixture_count"] > 0
            and all(type(sample.get(key)) in (int, float) and math.isfinite(sample[key])
                    and sample[key] > 0 for key in METRICS))


def summarize(samples):
    if not isinstance(samples, list) or len(samples) != REPEATS or not all(valid_sample(s) for s in samples):
        return {"status": "incomplete", "samples": samples}
    return {"status": "passed", "samples": samples,
            "metrics": {key: {"median": statistics.median(s[key] for s in samples),
                              "min": min(s[key] for s in samples),
                              "max": max(s[key] for s in samples)} for key in METRICS}}


def compare(baseline, current):
    errors = []
    if not isinstance(baseline, dict) or not isinstance(current, dict):
        return ["invalid report shape"]
    if baseline.get("status") != "measured" or current.get("status") != "measured":
        return ["baseline or run is incomplete"]
    if baseline.get("profile") != current.get("profile"):
        return ["runner/toolchain profile differs; measurements are not comparable"]
    expected = {s.name: s for s in SCENARIOS}
    if (not isinstance(baseline.get("scenarios"), dict) or not isinstance(current.get("scenarios"), dict)
            or set(baseline["scenarios"]) != set(expected) or set(current["scenarios"]) != set(expected)):
        return ["scenario coverage differs"]
    for name in sorted(expected):
        old, new = baseline["scenarios"][name], current["scenarios"][name]
        for label, value in (("baseline", old), ("current", new)):
            if (not isinstance(value, dict) or value.get("status") != "passed"
                    or summarize(value.get("samples", [])) != value):
                errors.append(f"{name}: invalid {label} summary")
            elif any(s["work"]["fixture_count"] != expected[name].count for s in value["samples"]):
                errors.append(f"{name}: incorrect {label} workload")
        if errors:
            continue
        for key in METRICS:
            before, after = old["metrics"][key]["median"], new["metrics"][key]["median"]
            if not math.isfinite(before) or not math.isfinite(after) or before <= 0 or after <= 0:
                errors.append(f"{name}: invalid {key}")
            elif after > before * 1.25:
                errors.append(f"{name}: {key} exceeds baseline by more than 25%")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", type=pathlib.Path, default=ROOT / "tests/scale-baseline.json")
    parser.add_argument("--record", action="store_true", help="record measurements, without replacing a baseline")
    args = parser.parse_args()
    if sys.flags.optimize:
        parser.error("optimized Python disables assertions and is not allowed")
    if platform.system() != "Linux" or not os.access(ROOT / "bin/mailbend-core", os.X_OK):
        parser.error("a Linux compiled build is required; interpreter fallback is not measured")
    deadline = time.monotonic() + LIMIT_SECONDS
    report = {"format": 1, "profile": profile(), "status": "incomplete", "scenarios": {},
              "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, timeout=10).strip(),
              "core_sha256": digest(ROOT / "bin/mailbend-core"),
              "load_average_start": os.getloadavg(), "measurement": "cold launcher, warm OS cache; fixture setup excluded"}
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def expired(_signal, _frame):
        raise TimeoutError("15-minute suite deadline reached")

    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, max(0.001, deadline - time.monotonic()))
    try:
        with tempfile.TemporaryDirectory(prefix="mailbend-scale-") as tmp:
            root = pathlib.Path(tmp)
            certs = certificates(root, clean_env(root))
            for scenario in SCENARIOS:
                samples = []
                for index in range(REPEATS):
                    if time.monotonic() >= deadline:
                        break
                    work = root / f"{scenario.name}-{index}"
                    work.mkdir()
                    try:
                        sample = run_sample(scenario, work, certs, deadline)
                    except (AssertionError, ValueError, RuntimeError, TimeoutError, subprocess.SubprocessError) as exc:
                        location = traceback.extract_tb(exc.__traceback__)[-1]
                        sample = {"status": "failed", "reason": type(exc).__name__,
                                  "failure_site": f"{pathlib.Path(location.filename).name}:{location.lineno}"}
                    samples.append(sample)
                    shutil.rmtree(work)
                    report["scenarios"][scenario.name] = summarize(samples)
                    args.output.write_text(json.dumps(report, indent=2) + "\n")
                    print(f"{scenario.name} sample {index + 1}: {sample['status']}", flush=True)
                    if sample["status"] != "passed":
                        break
            if len(report["scenarios"]) == len(SCENARIOS) and all(
                    value["status"] == "passed" for value in report["scenarios"].values()):
                report["status"] = "measured"
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        report["suite_seconds"] = LIMIT_SECONDS - (deadline - time.monotonic())
        report["load_average_end"] = os.getloadavg()
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    problems = [] if args.record else compare(json.loads(args.baseline.read_text()), report)
    if report["status"] != "measured":
        problems.append("not all exact workloads completed five successful samples")
    for problem in problems:
        print(problem, file=sys.stderr)
    return int(bool(problems))


if __name__ == "__main__":
    sys.exit(main())
