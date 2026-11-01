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
/api.md and /models.md): a Bearer key, the model "jev-1.14.0", questions of
type noul, choice (at most 255 options) or score (2 to 10 levels), and both
token limits: 32,000 for the state plus the longest question and 64,000 for
the state plus all questions. Tokens are counted as the UTF-8 bytes of the
compact JSON, the estimate MailBend packs with, so the fake checks only
MailBend's packing arithmetic, not TypeSafe's real tokenizer. A request
that breaks a rule gets 422 with a "detail", as TypeSafe answers.

A request with images (docs.typesafe.ai/images.md) gets 400 when an asset
is never referenced in the state or the questions, or when an image does
not decode: a PNG needs its signature, an IHDR, chunk CRCs that match, IDAT
data that inflates to a complete zlib stream, and an IEND; a JPEG needs SOI,
a frame header (SOF) before its scan (SOS), and EOI at the end. One such
image fails the whole request, with no partial answers.

Every 200 answer names the model that answered in "model", as TypeSafe's
SystemOneResponse does: the pinned model, unless a scenario says otherwise.

Answers are deterministic, from the state alone: a category is the folder
(or candidate) whose name appears in the email's subject, else the "none"
option; questions about injection answer yes when the email says "ignore
previous instructions"; reply_needed answers yes when the subject asks a
question. An email whose subject carries the marker "[disposable]" is
scripted as safe to throw away: every keep question answers no and the
disposability score is its top level with high confidence, unless the text
mentions a deadline, which keeps it open (keep_open_action answers yes).
A request about an outgoing message (a state with "outgoing") answers every
veto question yes when its subject or text carries the marker "[veto]",
else no. Everything else is a middling answer.

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
    refuse-assets     answer 400 to every request that carries assets
    model:<id>        answer as the model <id> instead of the pinned one
    no-model          answer without a "model" field
"""
import argparse
import base64
import binascii
import json
import os
from pathlib import Path
import socket
import ssl
import struct
import sys
import threading
import time
import zlib

TARGET = "api.typesafe.ai:443"
MODEL = "jev-1.14.0"
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


def images_problem(body, images_header):
    """assets and TypeSafe-Danger-Zone-Images are accepted only together."""
    if not isinstance(body, dict):
        return "the request takes exactly state, model and questions"
    has_assets = "assets" in body
    header_on = images_header == "true"
    if has_assets and not header_on:
        return "assets require TypeSafe-Danger-Zone-Images: true"
    if header_on and not has_assets:
        return "TypeSafe-Danger-Zone-Images: true requires assets"
    return None


PNG_SIGNATURE = bytes([137, 80, 78, 71, 13, 10, 26, 10])
# Every SOF marker except DHT (C4), JPG (C8) and DAC (CC).
JPEG_SOF = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}


def png_problem(data):
    """Why bytes are not a PNG that decodes; None when they are."""
    if data[:8] != PNG_SIGNATURE:
        return "not a PNG"
    pos, ihdr, idat = 8, None, b""
    while True:
        if pos + 12 > len(data):
            return "the PNG ends before IEND"
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        crc = data[pos + 8 + length:pos + 12 + length]
        if len(chunk) != length or len(crc) != 4:
            return "a PNG chunk is truncated"
        if zlib.crc32(kind + chunk) != struct.unpack(">I", crc)[0]:
            return f"the PNG {kind.decode('latin-1')} chunk fails its CRC"
        pos += 12 + length
        if kind == b"IHDR":
            ihdr = chunk
        elif kind == b"IDAT":
            idat += chunk
        elif kind == b"IEND":
            break
    if ihdr is None or len(ihdr) != 13 or not idat:
        return "the PNG has no IHDR or no IDAT"
    inflate = zlib.decompressobj()
    try:
        inflate.decompress(idat)
    except zlib.error:
        return "the PNG image data does not inflate"
    if not inflate.eof:
        return "the PNG image data is incomplete"
    return None


def jpeg_problem(data):
    """Why bytes are not a JPEG with a frame and a scan; None when they are."""
    if data[:2] != b"\xff\xd8":
        return "not a JPEG"
    pos, sof = 2, False
    while pos < len(data):
        if data[pos] != 0xFF:
            return "a JPEG marker is missing"
        while pos < len(data) and data[pos] == 0xFF:
            pos += 1
        if pos >= len(data):
            return "the JPEG ends inside a marker"
        marker = data[pos]
        pos += 1
        if marker == 0xD9:
            return "the JPEG has no scan"
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:
            continue
        if pos + 2 > len(data):
            return "a JPEG segment is truncated"
        length = struct.unpack(">H", data[pos:pos + 2])[0]
        if length < 2 or pos + length > len(data):
            return "a JPEG segment is truncated"
        if marker in JPEG_SOF:
            sof = True
        pos += length
        if marker == 0xDA:
            if not sof:
                return "the JPEG scan comes before its frame header"
            if data[-2:] != b"\xff\xd9" or len(data) - pos < 2:
                return "the JPEG does not end with EOI"
            return None
    return "the JPEG has no scan"


def assets_problem(body):
    """Why the assets of a request would be rejected (400); None when not."""
    assets = body.get("assets")
    if assets is None:
        return None
    if not isinstance(assets, dict) or not assets:
        return "assets must be a nonempty object"
    seen = json.dumps(body["state"], ensure_ascii=False) + json.dumps(body["questions"], ensure_ascii=False)
    for key, asset in assets.items():
        if key not in seen:
            return f"asset {key!r} is not referenced"
        if not isinstance(asset, dict) or asset.get("type") != "image":
            return f"asset {key!r} is not an image"
        try:
            data = base64.b64decode(asset.get("data_base64", ""), validate=True)
        except (binascii.Error, ValueError, TypeError):
            return f"asset {key!r} is not base64"
        fmt = asset.get("format")
        problem = png_problem(data) if fmt == "png" else jpeg_problem(data) if fmt == "jpeg" else "an unknown format"
        if problem:
            return f"image {key!r} is damaged or incomplete: {problem}"
    return None


def request_problem(body, images_header=None):
    """Why a request breaks the documented shape or the token limits."""
    keys = set(body) if isinstance(body, dict) else set()
    allowed = {"state", "model", "questions"}
    if isinstance(body, dict) and "assets" in body:
        allowed.add("assets")
    if not isinstance(body, dict) or keys != allowed:
        return "the request takes exactly state, model and questions"
    images = images_problem(body, images_header)
    if images:
        return images
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


def outgoing_answer(outgoing):
    """Every veto question about an outgoing message: yes when it carries
    the marker "[veto]" in its subject or text, else no."""
    seen = (str(outgoing.get("subject", "")) + " " + str(outgoing.get("text", ""))).lower()
    return {"type": "noul", "noul": 0.95 if "[veto]" in seen else 0.05}


def protected_environment(pid, proc=Path("/proc")):
    """A denied read counts only when proc ownership differs from the helper UID."""
    base = proc / str(pid)
    status = (base / "status").read_text()
    uid = next(line.split()[1:] for line in status.splitlines() if line.startswith("Uid:"))
    limits = (base / "limits").read_text()
    core = next(line.split()[4:6] for line in limits.splitlines() if line.startswith("Max core file size"))
    return (os.geteuid() != 0 and all(int(value) == os.geteuid() for value in uid)
            and (base / "environ").stat().st_uid != os.geteuid() and core == ["0", "0"])


def environ_names(proc=Path("/proc")):
    """Names from readable helpers, or verified non-dumpable markers."""
    found = []
    for base in proc.iterdir():
        if not base.name.isdigit():
            continue
        try:
            program = (base / "cmdline").read_bytes().split(b"\0")[0]
        except (PermissionError, FileNotFoundError, ProcessLookupError):
            continue
        if not program.endswith(b"mailbend-typesafe"):
            continue
        try:
            try:
                entries = (base / "environ").read_bytes().split(b"\0")
            except PermissionError:
                if not protected_environment(base.name, proc):
                    raise
                found.append({"non_dumpable": True})
            else:
                found.append({"names": sorted(e.split(b"=", 1)[0].decode("latin-1") for e in entries if e)})
        except (FileNotFoundError, ProcessLookupError):
            continue
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

    def reply(self, raw, auth, images_header=None):
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
        problem = request_problem(body, images_header)
        if problem:
            return 422, {"detail": problem}
        if kind == "refuse-assets" and "assets" in body:
            return 400, {"detail": "scenario refusal of a request with images"}
        problem = assets_problem(body)
        if problem:
            return 400, {"detail": problem}
        if kind == "malformed":
            return 200, ["not", "an", "answer"]
        state = body["state"]
        if isinstance(state, dict) and isinstance(state.get("outgoing"), dict):
            answers = {qid: outgoing_answer(state["outgoing"]) for qid in body["questions"]}
        else:
            emails = emails_by_uid(state)
            answers = {qid: answer(qid, q, emails) for qid, q in body["questions"].items()}
        answer_body = {"answers": answers, "usage": {"input_tokens": len(raw) // 4, "output_tokens": 0}}
        if kind == "no-model":
            return 200, answer_body
        return 200, {"model": arg if kind == "model" else MODEL, **answer_body}

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
        images_header = headers.get("typesafe-danger-zone-images")
        if lines[0] != "POST /v1/systemone HTTP/1.1" or headers.get("host") != "api.typesafe.ai":
            status, answer_body = 404, {"detail": "not found"}
        else:
            status, answer_body = self.reply(raw, headers.get("authorization", ""), images_header)
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = None
        self.log({**record, "request_line": lines[0], "status": status, "bytes": len(raw),
                  "user_agent": headers.get("user-agent"), "images_header": images_header,
                  "body": parsed})
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
