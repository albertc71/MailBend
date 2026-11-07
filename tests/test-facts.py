#!/usr/bin/env python3
"""Literal facts through the actual CLI or structured MCP and fake loopback mail."""
import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("e2e", ROOT / "tests/test-e2e.py")
e2e = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(e2e)
LINK = "https://meet.google.com/abc-defg-hij"
TEXT = "é😀 \n" + LINK + "\n"
EXPECTED = {"kind": "meeting_link", "value": LINK, "source": "text",
            "start": 4, "end": 40, "line": 2, "untrusted": True}


def fixture():
    result = copy.deepcopy(e2e.FIX)
    result["mailboxes"]["INBOX"]["messages"][0]["raw"] = (
        "Message-ID: <facts@example.com>\r\nFrom: alice@example.com\r\n"
        "To: tester@example.com\r\nSubject: Meeting\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n\r\n" + TEXT.encode("utf-8").decode("latin-1"))
    long_message = copy.deepcopy(result["mailboxes"]["INBOX"]["messages"][0])
    long_message["uid"] = 7
    long_message["raw"] += "history " * 600
    result["mailboxes"]["INBOX"]["messages"].append(long_message)
    return result


def integration_cases(srv):
    before = copy.deepcopy(srv.st()["mailboxes"])
    code, ordinary = e2e.tool(srv, "mail_get", {"uid": 1})
    assert code == 0 and "facts" not in ordinary and "facts_scan" not in ordinary, ordinary
    start = len(srv.log_lines())
    code, disabled = e2e.tool(srv, "mail_get", {"uid": 1, "facts": False})
    baseline_commands = srv.log_lines()[start:]
    assert code == 0 and disabled == ordinary, disabled
    start = len(srv.log_lines())
    code, enabled = e2e.tool(srv, "mail_get", {"uid": 1, "facts": True})
    assert code == 0 and {key: value for key, value in enabled.items()
                          if key not in ("facts", "facts_scan")} == ordinary, enabled
    assert srv.log_lines()[start:] == baseline_commands, srv.log_lines()[start:]
    print("PASS omitted/false parity and unchanged read commands")
    for mode in ("full", "text"):
        code, result = e2e.tool(srv, "mail_get", {"uid": 1, "facts": True, "projection": mode,
                                                "max_response_bytes": 4096})
        assert code == 0 and result["facts"] == [EXPECTED] and result["text"] == TEXT, result
        assert ("html" in result) == (mode == "full"), result
        assert len(json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode()) <= 4096, result
    print("PASS full/text projections and final UTF-8 byte budget")
    for extra in ({"projection": "html"}, {"projection": "metadata"},
                  {"section": "list"}, {"section": "text"}, {"section": "1"}, {"section": " "}):
        start = len(srv.log_records())
        code, result = e2e.tool(srv, "mail_get", {"uid": 1, "facts": True, **extra})
        assert code != 0 and "whole-message" in result.get("error", ""), result
        assert len(srv.log_records()) == start, result
    start = len(srv.log_records())
    code, result = e2e.tool(srv, "mail_get", {"uid": 1, "facts": "yes"})
    assert code != 0 and len(srv.log_records()) == start, result
    print("PASS unsupported facts requests fail before network access")
    code, projected = e2e.tool(srv, "mail_get", {"uid": 1, "projection": "text", "max_response_bytes": 4096})
    assert code == 0, projected
    budget = len(json.dumps(projected, ensure_ascii=False, separators=(",", ":")).encode())
    args = {"uid": 1, "projection": "text", "max_response_bytes": budget}
    code, baseline = e2e.tool(srv, "mail_get", args)
    assert code == 0 and baseline["text"] == TEXT and baseline["response"]["output_truncated"] is False, baseline
    start = len(srv.log_lines())
    code, refused = e2e.tool(srv, "mail_get", {**args, "facts": True})
    assert code != 0 and "projected result and facts" in refused.get("error", ""), refused
    assert srv.log_lines()[start:] == baseline_commands, srv.log_lines()[start:]
    code, shortened = e2e.tool(srv, "mail_get", {"uid": 7, "projection": "text", "max_response_bytes": 2000})
    assert code == 0 and shortened["response"]["output_truncated"] is True, shortened
    code, refused = e2e.tool(srv, "mail_get", {"uid": 7, "facts": True, "projection": "text", "max_response_bytes": 2000})
    assert code != 0 and "projected result and facts" in refused.get("error", ""), refused
    print("PASS finalizer overflow raises budget without another read or silent fact loss")
    code, prefix = e2e.tool(srv, "mail_get", {"uid": 7, "facts": True, "max_bytes": 1024})
    assert code == 0 and prefix["truncated"] is True and prefix["facts"] == [EXPECTED], prefix
    assert prefix["facts_scan"]["limited"] is True, prefix
    assert srv.st()["mailboxes"] == before, "read changed mailbox state"
    assert not any(" SELECT " in line or any(command in line for command in e2e.MUTATING_COMMANDS)
                   for line in srv.log_lines()), srv.log_lines()
    assert all("BODY.PEEK" in line for line in srv.log_lines() if " UID FETCH " in line), srv.log_lines()
    print("PASS fetched prefixes retain delimited facts and all reads leave mail unchanged")


def jev_cases(srv, work):
    ts = e2e.TypeSafe(work)
    try:
        env = e2e.jev_env(ts, e2e.typesafe_key_file(work),
                          MAILBEND_TYPESAFE_CONTENT="body", MAILBEND_TYPESAFE_ZERO_RETENTION="1")
        before = copy.deepcopy(srv.st()["mailboxes"])
        args = {"uid": 1, "projection": "text", "max_response_bytes": 4096}
        code, baseline, commands, asked = e2e.gate_call(srv, ts, "mail_get", {**args, "facts": False}, **env)
        code2, enabled, observed, sent = e2e.gate_call(srv, ts, "mail_get", {**args, "facts": True}, **env)
        assert code == code2 == 0 and enabled["facts"] == [EXPECTED], (baseline, enabled)
        assert baseline["jev"]["status"] == "checked" and baseline["jev"]["content"] == "body", baseline
        assert {key: value for key, value in enabled.items() if key not in ("facts", "facts_scan")} == baseline
        assert asked and [q["body"] for q in asked] == [q["body"] for q in sent], (asked, sent)
        assert any(email.get("text") == TEXT for q in asked for email in q["body"]["state"]["emails"])
        assert commands == observed and srv.st()["mailboxes"] == before, (commands, observed)
        assert not any(e2e.TYPESAFE_KEY in output for output in e2e.outputs), "synthetic key leaked"
        print("PASS facts preserve body-mode Jev input, annotation and read commands")
    finally:
        ts.stop()


def completeness_fixture():
    result = fixture()
    header = ("Message-ID: <boundary@example.com>\r\nFrom: alice@example.com\r\n"
              "To: tester@example.com\r\nSubject: Boundary\r\n"
              "Content-Type: text/plain; charset=us-ascii\r\n\r\n")
    template = result["mailboxes"]["INBOX"]["messages"][0]
    window = header + " " * (1024 - len(header) - 36) + LINK + ".evil.invalid"
    result["mailboxes"]["INBOX"]["messages"] = [
        {**template, "uid": 1, "raw": window, "reported_size": 1024},
        {**template, "uid": 2, "raw": header + LINK, "reported_size": 1},
        {**template, "uid": 3, "raw": header + LINK},
        {**template, "uid": 4, "raw": header + LINK + "\n", "reported_size": 1},
    ]
    return result


def completeness_cases(srv):
    code, cut = e2e.tool(srv, "mail_get", {"uid": 1, "facts": True, "max_bytes": 1024})
    assert code == 0 and cut.get("text", "").endswith(LINK), cut
    assert cut["truncated"] is False, cut
    assert cut["facts"] == [] and cut["facts_scan"]["limited"] is True, cut
    print("PASS full fetch window cannot complete a token despite matching reported size")
    code, lied = e2e.tool(srv, "mail_get", {"uid": 2, "facts": True, "max_bytes": 1024})
    assert code == 0 and lied["text"] == LINK and lied["truncated"] is False, lied
    assert lied["facts"] == [] and lied["facts_scan"]["limited"] is True, lied
    print("PASS inconsistent size cannot complete a token below the fetch window")
    code, complete = e2e.tool(srv, "mail_get", {"uid": 3, "facts": True, "max_bytes": 1024})
    assert code == 0 and complete["facts"] == [{**EXPECTED, "start": 0, "end": 36, "line": 1}], complete
    assert complete["facts_scan"]["limited"] is False, complete
    code, delimited = e2e.tool(srv, "mail_get", {"uid": 4, "facts": True, "max_bytes": 1024})
    assert code == 0 and delimited["facts"] == [{**EXPECTED, "start": 0, "end": 36, "line": 1}], delimited
    assert delimited["facts_scan"]["limited"] is True, delimited
    print("PASS complete EOF and independently delimited prefix retain inhabited facts")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--completeness-only", action="store_true")
    parser.add_argument("--basic-only", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mailbend-facts-") as work:
        subprocess.run(["sh", str(ROOT / "tests/gen-test-certs.sh"), str(Path(work) / "certs")],
                       check=True, capture_output=True)
        srv = e2e.Server(work, fixture=completeness_fixture() if args.completeness_only else fixture())
        try:
            if args.completeness_only:
                completeness_cases(srv)
                assert all(ok for _, ok in e2e.results), e2e.results
                assert not any(e2e.PASSWORD in output for output in e2e.outputs), "synthetic password leaked"
                return
            code, result = e2e.tool(srv, "mail_get", {"uid": 1, "facts": True})
            assert code == 0 and result.get("facts") == [EXPECTED], result
            assert result["text"] == TEXT, result
            assert result["facts_scan"] == {"scope": "returned_text", "limited": False}, result
            assert all(ok for _, ok in e2e.results), e2e.results
            print("PASS literal facts from returned text")
            if not args.basic_only:
                integration_cases(srv)
                jev_cases(srv, work)
        finally:
            srv.stop()
        if not args.basic_only and not args.completeness_only:
            srv = e2e.Server(work, fixture=completeness_fixture())
            try:
                completeness_cases(srv)
            finally:
                srv.stop()
        assert all(ok for _, ok in e2e.results), e2e.results
        assert not any(e2e.PASSWORD in output for output in e2e.outputs), "synthetic password leaked"
        print("PASS schema validation and credential redaction")


if __name__ == "__main__":
    main()
