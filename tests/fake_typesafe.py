#!/usr/bin/env python3
"""A fake TypeSafe API (POST /v1/systemone) behind a local HTTPS proxy, used
to exercise mailbend-typesafe, mail_classify and mail_triage without the
real service.

Usage:
    python3 fake_typesafe.py --certdir DIR --key KEY --log FILE [--scenario NAME]

Listens on 127.0.0.1 with an OS-assigned port and prints one line

    READY proxy=<port>

The helper reaches it with https_proxy=http://127.0.0.1:<port>: the proxy
accepts only "CONNECT api.typesafe.ai:443", then serves TLS itself with the
test certificate typesafe.pem (DNS:api.typesafe.ai, signed by the test CA in
--certdir, which the helper trusts through MAILBEND_CA_FILE).

Each request is checked against the documented shapes (docs.typesafe.ai
/api.md and /models.md): a Bearer key, the model "jev-1.13.0", questions of
type noul, choice (at most 255 options) or score (2 to 10 levels), and both
token limits: 32,000 for the state plus the longest question and 64,000 for
the state plus all questions. Tokens are counted as the UTF-8 bytes of the
compact JSON, the estimate MailBend packs with, so the fake checks only
MailBend's packing arithmetic, not TypeSafe's real tokenizer. A request
that breaks a rule gets 422 with a "detail", as TypeSafe answers.

Answers are deterministic, from the state alone: a category is the folder
(or candidate) whose name appears in the email's subject, else the "none"
option; questions about injection answer yes when the email says "ignore
previous instructions"; reply_needed answers yes when the subject asks a
question. An email whose subject carries the marker "[disposable]" is
scripted as safe to throw away: every keep question answers no and the
disposability score is its top level with high confidence, unless the text
mentions a deadline, which keeps it open (keep_open_action answers yes).
Everything else is a middling answer.

Every request is appended to --log as JSONL: the CONNECT target, the names
(never the values) of the environment variables of each running
mailbend-typesafe process, the HTTP status sent, the request's byte count
and the parsed request body.

Scenarios (--scenario):
    ok                answer every valid request (the default)
    status:<code>     answer every request with this HTTP status and a detail
    echo-key          answer 401 with a detail that repeats the Bearer token
    over:<bytes>      answer 422 to a request body of more than <bytes> bytes
    fail-after:<n>    answer the first <n> requests, then 422 to every other
    malformed         answer 200 with a body that is not TypeSafe's JSON
    slow[:<seconds>]  wait 30 (or <seconds>) seconds before answering
"""
import argparse
import json
import os
import socket
import ssl
import sys
import threading
import time

TARGET = "api.typesafe.ai:443"
MODEL = "jev-1.13.0"
STATE_LIMIT = 32000
REQUEST_LIMIT = 64000


def compact(value) -> int:
    """UTF-8 bytes of a value as compact JSON."""
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def question_problem(qid, q):
    """Why a question breaks the documented shape; None when it does not."""
    if not isinstance(q, dict) or not isinstance(q.get("instructions"), str):
        return f"{qid}: a question needs instructions"
    kind = q.get("type")
    criteria = q.get("criteria")
    if kind == "noul":
        return None
    if kind == "choice":
        if not isinstance(criteria, dict) or not 1 <= len(criteria) <= 255:
            return f"{qid}: a choice takes 1 to 255 options"
        if not all(v is None or isinstance(v, str) for v in criteria.values()):
            return f"{qid}: a choice option is a description or null"
        return None
    if kind == "score":
        if not isinstance(criteria, list) or not 2 <= len(criteria) <= 10:
            return f"{qid}: a score takes 2 to 10 levels"
        return None
    return f"{qid}: unknown question type {kind!r}"


def request_problem(body):
    """Why a request breaks the documented shape or the token limits."""
    if not isinstance(body, dict) or set(body) != {"state", "model", "questions"}:
        return "the request takes exactly state, model and questions"
    if body["model"] != MODEL:
        return f"unknown model {body['model']!r}"
    questions = body["questions"]
    if not isinstance(questions, dict) or not questions:
        return "questions must be a nonempty object"
    for qid, q in questions.items():
        problem = question_problem(qid, q)
        if problem:
            return problem
    state = compact(body["state"])
    sizes = [compact({qid: q}) for qid, q in questions.items()]
    if state + max(sizes) > STATE_LIMIT:
        return f"state and longest question take {state + max(sizes)} tokens, over {STATE_LIMIT}"
    if state + sum(sizes) > REQUEST_LIMIT:
        return f"state and questions take {state + sum(sizes)} tokens, over {REQUEST_LIMIT}"
    return None


def emails_by_uid(state):
    emails = state.get("emails", []) if isinstance(state, dict) else []
    return {str(e.get("uid")): e for e in emails if isinstance(e, dict)}


def answer(qid, q, emails):
    """A deterministic answer from the email the question names."""
    uid, _, name = qid[1:].partition("_")
    email = emails.get(uid, {})
    subject = str(email.get("subject", ""))
    text = (subject + " " + str(email.get("text", ""))).lower()
    kind = q["type"]
    disposable = "[disposable]" in subject.lower()
    if kind == "choice":
        # The category options end with MailBend's "none" key, whatever it is called.
        options = list(q["criteria"])
        named = [k for k in options[:-1] if k.lower() in subject.lower()]
        if name == "suggested_action":
            pick = "review" if "ignore previous instructions" in text else "read_later"
        else:
            pick = max(named, key=len) if named else options[-1]
        return {"type": "choice", "choice": pick, "probabilities": {pick: 0.9}, "confidence": 0.9}
    if kind == "score" and name == "disposable" and disposable:
        return {"type": "score", "score": 2.0, "legend": q["criteria"],
                "probabilities": [0.0, 0.05, 0.95], "confidence": 0.95}
    if kind == "score":
        return {"type": "score", "score": 1.0, "legend": q["criteria"],
                "probabilities": [0.1, 0.8, 0.1], "confidence": 0.8}
    if name == "keep_open_action" and "deadline" in text:
        yes = 0.95
    elif name.startswith("keep_") and disposable:
        yes = 0.05
    elif name == "injection":
        yes = 0.95 if "ignore previous instructions" in text else 0.02
    elif name == "reply_needed":
        yes = 0.9 if "?" in subject else 0.1
    else:
        yes = 0.5
    return {"type": "noul", "noul": yes}


def environ_names():
    """The names of the environment variables of each running helper."""
    found = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                program = f.read().split(b"\0")[0]
            if not program.endswith(b"mailbend-typesafe"):
                continue
            with open(f"/proc/{pid}/environ", "rb") as f:
                entries = f.read().split(b"\0")
        except OSError:
            continue
        found.append(sorted(e.split(b"=", 1)[0].decode("latin-1") for e in entries if e))
    return found


class Fake:
    def __init__(self, key, scenario, log_path, ssl_ctx):
        self.key = key
        self.scenario = scenario
        self.log_path = log_path
        self.ssl_ctx = ssl_ctx
        self.lock = threading.Lock()
        self.count = 0

    def log(self, record):
        with self.lock:
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")

    def reply(self, raw, auth):
        """The status and JSON body for one request."""
        with self.lock:
            self.count += 1
            n = self.count
        kind, _, arg = self.scenario.partition(":")
        if kind == "slow":
            time.sleep(float(arg or 30))
        if kind == "echo-key":
            return 401, {"detail": f"invalid key {auth}"}
        if auth != f"Bearer {self.key}":
            return 401, {"detail": "Invalid API key"}
        if kind == "status":
            return int(arg), {"detail": f"scenario status {arg}"}
        if kind == "over" and len(raw) > int(arg):
            return 422, {"detail": f"request of {len(raw)} bytes is over {arg}"}
        if kind == "fail-after" and n > int(arg):
            return 422, {"detail": [{"loc": ["body", "questions"], "msg": "scenario refusal"}]}
        try:
            body = json.loads(raw)
        except ValueError:
            return 422, {"detail": "the request is not JSON"}
        problem = request_problem(body)
        if problem:
            return 422, {"detail": problem}
        if kind == "malformed":
            return 200, ["not", "an", "answer"]
        emails = emails_by_uid(body["state"])
        answers = {qid: answer(qid, q, emails) for qid, q in body["questions"].items()}
        return 200, {"answers": answers, "usage": {"input_tokens": len(raw) // 4, "output_tokens": 0}}

    def serve(self, conn):
        """One proxied connection: CONNECT, then one HTTPS request."""
        with conn:
            conn.settimeout(60)
            head = b""
            while b"\r\n\r\n" not in head and len(head) < 8192:
                chunk = conn.recv(1024)
                if not chunk:
                    return
                head += chunk
            line = head.split(b"\r\n", 1)[0].decode("latin-1")
            parts = line.split()
            target = parts[1] if len(parts) == 3 and parts[0] == "CONNECT" else ""
            record = {"connect": line, "env_names": environ_names()}
            if target != TARGET:
                conn.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                self.log({**record, "status": 403})
                return
            conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            try:
                tls = self.ssl_ctx.wrap_socket(conn, server_side=True)
            except (ssl.SSLError, OSError) as e:
                self.log({**record, "tls_error": str(e)})
                return
            with tls:
                self.serve_https(tls, record)

    def serve_https(self, tls, record):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = tls.recv(65536)
            if not chunk:
                return
            data += chunk
        head, _, rest = data.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        headers = {k.strip().lower(): v.strip() for k, _, v in (h.partition(":") for h in lines[1:])}
        length = int(headers.get("content-length", "0"))
        while len(rest) < length:
            chunk = tls.recv(65536)
            if not chunk:
                break
            rest += chunk
        raw = rest[:length]
        if lines[0] != "POST /v1/systemone HTTP/1.1" or headers.get("host") != "api.typesafe.ai":
            status, answer_body = 404, {"detail": "not found"}
        else:
            status, answer_body = self.reply(raw, headers.get("authorization", ""))
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = None
        self.log({**record, "request_line": lines[0], "status": status, "bytes": len(raw),
                  "user_agent": headers.get("user-agent"), "body": parsed})
        payload = json.dumps(answer_body).encode("utf-8")
        tls.sendall(f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\n"
                    f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode("latin-1") + payload)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--certdir", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--scenario", default="ok")
    args = ap.parse_args()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(args.certdir, "typesafe.pem"), os.path.join(args.certdir, "typesafe-key.pem"))
    fake = Fake(args.key, args.scenario, args.log, ctx)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(16)
    print(f"READY proxy={listener.getsockname()[1]}", flush=True)
    while True:
        conn, _ = listener.accept()
        threading.Thread(target=fake.serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
