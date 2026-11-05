#!/usr/bin/env python3
"""Optional, model-free SDK smoke. --real also exercises MailBend and fake mail."""

import argparse
import asyncio
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def stub_server(log):
    names = ["mail_probe", "mail_search", "mail_get", "mail_send", "mail_reply",
             "mail_forward", "mail_delete", "mail_create_folder"]
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request["method"]
        if method == "initialize":
            result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "synthetic-sdk-boundary", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": name, "description": "Synthetic test tool",
                                 "inputSchema": {"type": "object", "properties": {}}}
                                for name in names]}
        elif method == "tools/call":
            with Path(log).open("a") as output:
                output.write(json.dumps(request["params"]) + "\n")
            value = {"ok": True}
            if request["params"]["name"] == "mail_probe":
                value = {"password_in_environment": "MAILBEND_APP_PASSWORD" in os.environ,
                         "typesafe_key_in_environment": "MAILBEND_TYPESAFE_KEY_FILE" in os.environ,
                         "typesafe": os.environ.get("MAILBEND_TYPESAFE"),
                         "read_only": os.environ.get("MAILBEND_READ_ONLY"),
                         "drafts_only": os.environ.get("MAILBEND_DRAFTS_ONLY")}
            result = {"content": [{"type": "text", "text": json.dumps(value)}]}
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


async def smoke(launcher, environment, observations, verify_effect, *, real=False):
    sys.path.insert(0, str(ROOT / "examples/frameworks"))
    from openai_agents import mailbend_server, run_with_approvals
    from agents import Agent, Runner, set_tracing_disabled
    from agents.testing import ScriptedModel, assistant_message, function_call

    set_tracing_disabled(True)
    defaults_env = {name: value for name, value in environment.items()
                    if name not in ("MAILBEND_READ_ONLY", "MAILBEND_DRAFTS_ONLY")}
    defaults_env.update(MAILBEND_APP_PASSWORD="synthetic-unused",
                        MAILBEND_TYPESAFE_KEY_FILE="/synthetic-unused", MAILBEND_TYPESAFE="1")
    async with mailbend_server(launcher, defaults_env) as defaults:
        probe = await defaults.call_tool("mail_probe", {})
        assert not probe.isError, "safe mail_probe failed"
        if real:
            assert {tool.name for tool in await defaults.list_tools()} == {
                "mail_probe", "mail_search", "mail_get"}, "defaults exposed a write tool"
        else:
            assert json.loads(probe.content[0].text) == {
                "password_in_environment": False, "typesafe_key_in_environment": False,
                "typesafe": "0", "read_only": "1", "drafts_only": "1"}
        print("PASS safe child environment defaults and credential exclusion")

    calls = {
        "mail_send": {"to": ["recipient@example.com"], "subject": "Synthetic",
                      "body": "Approval test"},
        "mail_reply": {"folder": "INBOX", "uid": 1, "uidvalidity": 1700000001,
                       "body": "Synthetic reply", "as_draft": False},
        "mail_forward": {"folder": "INBOX", "uid": 1, "uidvalidity": 1700000001,
                         "to": ["recipient@example.com"], "as_draft": False},
        "mail_delete": {"folder": "INBOX", "uids": [1], "uidvalidity": 1700000001,
                        "confirm": "permanently-delete"},
    }
    async with mailbend_server(launcher, environment) as server:
        assert {tool.name for tool in await server.list_tools()} == {
            "mail_probe", "mail_search", "mail_get", "mail_send", "mail_reply",
            "mail_forward", "mail_delete"}, "unexpected exposed tool set"
        print("PASS actual tools/list filters out other operations")

        def scripted(steps):
            model = ScriptedModel([*steps, [assistant_message("done")]])
            return model, Agent(name="Offline approval smoke", model=model, mcp_servers=[server])

        model, agent = scripted([[function_call("mail_probe", {}, call_id="probe")]])
        result = await Runner.run(agent, "Exercise the scripted call.")
        assert not result.interruptions and result.final_output == "done"
        model.assert_complete()
        print("PASS actual mail_probe runs without approval")

        for name, arguments in calls.items():
            model, agent = scripted([[function_call(name, arguments, call_id=name + "-denied")]])
            before = observations()
            result = await Runner.run(agent, "Exercise the scripted call.")
            assert len(result.interruptions) == 1, name + " must pause before dispatch"
            item = result.interruptions[0]
            assert item.tool_name == name and json.loads(item.raw_item.arguments) == arguments
            assert observations() == before, name + " reached mail before approval"
            state = result.to_state()
            state.reject(item)
            result = await Runner.run(agent, state)
            assert result.final_output == "done" and not result.interruptions
            assert observations() == before, "denied " + name + " reached mail"
            model.assert_complete()
            print("PASS " + name + " pauses; rejection leaves command log and state unchanged")

        for answer in ("", "no", "YES", "yes please", None):
            arguments = {**calls["mail_send"], "body": "Untrusted \x1b[2J \u202e text"}
            model, agent = scripted([[function_call("mail_send", arguments, call_id="input")]])
            before = observations()
            prompts = []

            def decline(prompt):
                prompts.append(prompt)
                assert "\x1b" not in prompt and "\u202e" not in prompt
                shown = json.loads(prompt.split("\nApprove this one call?")[0])
                assert shown == {"tool": "mail_send", "arguments": arguments}
                if answer is None:
                    raise EOFError
                return answer

            result = await run_with_approvals(agent, "Exercise the scripted call.", decline)
            assert len(prompts) == 1 and result.final_output == "done"
            assert observations() == before, "non-yes input dispatched mail"
            model.assert_complete()
        print("PASS invalid input and EOF reject; the exact call display escapes terminal controls")

        model, agent = scripted([
            [function_call("mail_send", calls["mail_send"], call_id="approved-send")],
            [function_call("mail_send", {**calls["mail_send"], "to": ["other@example.com"]},
                           call_id="changed-send")],
            [function_call("mail_send", calls["mail_send"], call_id="new-identical-send")],
        ])
        checkpoints = []

        def approve_once(prompt):
            checkpoints.append(observations())
            return "yes" if len(checkpoints) == 1 else "no"

        result = await run_with_approvals(agent, "Exercise the scripted calls.", approve_once)
        assert len(checkpoints) == 3, "a later send reused approval"
        assert checkpoints[0] != checkpoints[1], "approved send did not reach the observer"
        assert checkpoints[1] == checkpoints[2] == observations(), "later denied send ran"
        assert result.final_output == "done"
        model.assert_complete()
        verify_effect("mail_send")
        print("PASS one approved send is observed; changed and new identical calls need fresh approval")

        model, agent = scripted([[function_call("mail_delete", calls["mail_delete"],
                                               call_id="approved-delete")]])
        await run_with_approvals(agent, "Exercise the scripted call.", lambda _: "yes")
        model.assert_complete()
        verify_effect("mail_delete")
        print("PASS approved synthetic deletion proves the delete observer works")


def real_smoke(work):
    from email.parser import Parser
    from email.policy import default
    import selectors
    import subprocess

    for name in ("mailbend-core", "mailbend-tls", "mailbend-stdio", "mailbend-attach"):
        assert (ROOT / "bin" / name).is_file(), "build this checkout with scripts/install.sh first"
    fixture = json.loads((ROOT / "tests/fixtures/mailbox.json").read_text())
    password = work / "password"
    password.write_text(fixture["password"])
    password.chmod(0o600)
    subprocess.run(["sh", str(ROOT / "tests/gen-test-certs.sh"), str(work / "certs"), "--demo"],
                   check=True, capture_output=True, timeout=30)
    state, log = work / "state.json", work / "mail.jsonl"
    command = [sys.executable, str(ROOT / "tests/fake_mail_server.py"),
               "--certdir", str(work / "certs"), "--fixture", str(ROOT / "tests/fixtures/mailbox.json"),
               "--state", str(state), "--log", str(log)]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            assert selector.select(10), "fake mail startup timed out"
        ready = process.stdout.readline().split()
        assert ready and ready[0] == "READY", "fake mail did not start"
        ports = dict(part.split("=") for part in ready[1:])
        environment = {
            "MAILBEND_EMAIL": fixture["user"], "MAILBEND_PASSWORD_FILE": str(password),
            "MAILBEND_IMAP_HOST": "localhost", "MAILBEND_IMAP_PORT": ports["imap"],
            "MAILBEND_SMTP_HOST": "localhost", "MAILBEND_SMTP_PORT": ports["smtp"],
            "MAILBEND_IMAP_CONNECT_IP": "127.0.0.1", "MAILBEND_SMTP_CONNECT_IP": "127.0.0.1",
            "MAILBEND_CA_FILE": str(work / "certs/ca.pem"), "MAILBEND_TIMEOUT_MS": "5000",
            "MAILBEND_READ_ONLY": "0", "MAILBEND_DRAFTS_ONLY": "0", "MAILBEND_SAVE_SENT": "0",
        }

        def observations():
            return state.read_bytes(), log.read_bytes() if log.exists() else b""

        def verify_effect(name):
            actual = json.loads(state.read_text())
            records = [json.loads(line) for line in log.read_text().splitlines()]
            assert len(actual["sent"]) == 1, "expected exactly one synthetic SMTP send"
            sent = actual["sent"][0]
            assert sent["rcpt_to"] == ["recipient@example.com"]
            message = Parser(policy=default).parsestr(sent["data"])
            assert str(message["Subject"]) == "Synthetic"
            assert message.get_body(preferencelist=("plain",)).get_content().strip() == "Approval test"
            assert any(row["proto"] == "smtp" and row["line"] == "DATA" for row in records)
            remaining = [message["uid"] for message in actual["mailboxes"]["INBOX"]["messages"]]
            if name == "mail_send":
                assert remaining == [1, 2, 3, 4, 5, 6], "send changed inbox messages"
            else:
                assert remaining == [2, 3, 4, 5, 6], "approved deletion did not remove UID 1"
                assert any(" UID EXPUNGE 1" in row["line"] for row in records)

        asyncio.run(smoke(ROOT / "scripts/mailbend", environment, observations, verify_effect, real=True))
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        process.stdout.close()
    print("PASS real MailBend launcher + local TLS fake mail; no model API or provider account")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--real", action="store_true", help="use this checkout and local TLS fake mail")
    parser.add_argument("--stub-server", metavar="LOG", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.stub_server:
        stub_server(args.stub_server)
        return
    with tempfile.TemporaryDirectory(prefix="mailbend-framework-") as directory:
        work = Path(directory)
        if args.real:
            real_smoke(work)
            return
        log = work / "calls.jsonl"
        launcher = work / "mailbend"
        launcher.write_text("#!/bin/sh\nexec " + shlex.join(
            [sys.executable, str(Path(__file__).resolve()), "--stub-server", str(log)]) + "\n")
        launcher.chmod(0o700)
        def verify_effect(name):
            calls = [json.loads(line)["name"] for line in log.read_text().splitlines()]
            assert calls.count("mail_send") == 1
            assert calls.count("mail_delete") == (1 if name == "mail_delete" else 0)

        asyncio.run(smoke(launcher, {"MAILBEND_READ_ONLY": "0", "MAILBEND_DRAFTS_ONLY": "0"},
                          lambda: log.read_text() if log.exists() else "", verify_effect))
    print("PASS SDK-only stub smoke; no MailBend transport coverage")


if __name__ == "__main__":
    main()
