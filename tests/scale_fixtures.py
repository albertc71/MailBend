"""Deterministic, synthetic inputs for the public-launcher scale suite."""
import base64
from dataclasses import dataclass

from image_fixtures import png


MIB = 1024 * 1024
USER = "scale@example.com"
PASSWORD = "synthetic-scale-password"
UIDVALIDITY = 140


@dataclass(frozen=True)
class Scenario:
    name: str
    tool: str
    arguments: dict
    count: int
    kind: str


SCENARIOS = (
    Scenario("search-100000", "mail_search", {"limit": 200}, 100000, "search"),
    Scenario("folders-1000", "mail_list_folders", {}, 1000, "folders"),
    Scenario("folders-5000", "mail_list_folders", {}, 5000, "folders"),
    Scenario("read-16mib", "mail_get", {"uid": 1, "max_bytes": 16 * MIB}, 16 * MIB, "read"),
    Scenario("forward-25mib", "mail_forward", {
        "uid": 1, "uidvalidity": UIDVALIDITY, "to": ["recipient@example.com"],
        "body": "Synthetic scale forward."}, 25 * MIB, "forward"),
    Scenario("thread-1000", "mail_get_thread", {"uid": 1}, 1000, "thread"),
    Scenario("classify-images-50", "mail_classify", {"uids": list(range(1, 51))}, 50, "classify"),
)


def message(uid, body="Synthetic body.\r\n", headers=""):
    return {"uid": uid, "flags": [], "internaldate": "01-Oct-2026 09:00:00 +0000",
            "raw": f"From: sender@example.com\r\nTo: {USER}\r\nSubject: Scale {uid}\r\n"
                   + headers + "Content-Type: text/plain; charset=us-ascii\r\n\r\n" + body,
            "measure_sections": True}


def sized_message(size):
    row = message(1)
    header = row["raw"].split("\r\n\r\n", 1)[0] + "\r\n\r\n"
    end = "SCALE-END\r\n"
    count = size - len(header) - len(end)
    body = ("x" * 76 + "\r\n") * (count // 78) + "x" * (count % 78) + end
    row["raw"] = header + body
    assert len(row["raw"].encode("ascii")) == size
    return row


def image_message(uid):
    encoded = base64.encodebytes(png(280, 280)).decode("ascii").replace("\n", "\r\n")
    return {"uid": uid, "flags": [], "internaldate": "01-Oct-2026 09:00:00 +0000",
            "measure_sections": True,
            "raw": f"From: sender@example.com\r\nTo: {USER}\r\nSubject: Scale {uid}\r\n"
                   "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=scale\r\n\r\n"
                   "--scale\r\nContent-Type: text/plain\r\n\r\nSynthetic image.\r\n"
                   "--scale\r\nContent-Type: image/png\r\n"
                   "Content-Disposition: attachment; filename=scale.png\r\n"
                   "Content-Transfer-Encoding: base64\r\n\r\n" + encoded + "--scale--\r\n"}


def fixture(scenario):
    boxes = {"INBOX": {"uidvalidity": UIDVALIDITY, "messages": []},
             "Sent": {"uidvalidity": UIDVALIDITY + 1, "special": ["\\Sent"], "messages": []}}
    if scenario.kind == "folders":
        for i in range(scenario.count - len(boxes)):
            boxes[f"Folder-{i:05d}"] = {"uidvalidity": i + 1000, "messages": []}
    elif scenario.kind in ("read", "forward"):
        boxes["INBOX"]["messages"] = [sized_message(scenario.count)]
    elif scenario.kind == "thread":
        prefix = "same-long-prefix-" * 16
        root = f"<{prefix}0001@example.com>"
        boxes["INBOX"]["messages"] = [message(i, headers=
            f"Message-ID: <{prefix}{i:04d}@example.com>\r\n"
            + (f"In-Reply-To: {root}\r\nReferences: {root}\r\n" if i > 1 else ""))
            for i in range(1, scenario.count + 1)]
    elif scenario.kind == "classify":
        boxes["INBOX"]["messages"] = [image_message(i) for i in range(1, scenario.count + 1)]
    else:
        boxes["INBOX"]["messages"] = [message(i) for i in range(1, scenario.count + 1)]
    return {"user": USER, "password": PASSWORD, "mailboxes": boxes}
