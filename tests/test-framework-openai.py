#!/usr/bin/env python3
"""Optional, model-free SDK smoke. --real also exercises MailBend and fake mail."""

import argparse
import asyncio
import copy
import contextlib
import io
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def synthetic_identity(arguments):
    """The relevant whole-message metadata contract, never real account data."""
    return {"folder": arguments.get("folder", "INBOX"), "uid": arguments["uid"],
            "uidvalidity": arguments["uidvalidity"], "size": 1024, "truncated": False,
            "from": "alice@example.com", "to": "tester@example.com", "cc": "list@example.com",
            "reply_to": "reply-to@example.com", "date": "Sun, 20 Sep 2026 09:00:00 +0000",
            "subject": "Lunch tomorrow?", "message_id": "<msg1@example.com>",
            "attachments": [{"filename": "synthetic.txt", "content_type": "text/plain", "size": 16}],
            "response": {"projection": "metadata", "max_bytes": 65536,
                         "budget_scope": "result_json_utf8", "output_truncated": False,
                         "request_more": "Synthetic fixture only"}}


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
            arguments = request["params"].get("arguments", {})
            if arguments.get("dry_run"):
                recipients = (["reply-to@example.com", "list@example.com"]
                              if request["params"]["name"] == "mail_reply"
                              else arguments["to"] + arguments.get("cc", []) + arguments.get("bcc", []))
                value = {"dry_run": True, "smtp": {"from": "tester@example.com",
                         "rcpt": recipients, "data": "<100 bytes>", "sent_copy": False}}
            if request["params"]["name"] == "mail_get":
                value = synthetic_identity(arguments)
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


async def smoke(launcher, environment, observations, verify_effect, verify_read_only, *, real=False):
    sys.path.insert(0, str(ROOT / "examples/frameworks"))
    import openai_agents as recipe
    from openai_agents import mailbend_server, run_with_approvals
    from agents import Agent, Runner, set_tracing_disabled
    from agents.testing import ScriptedModel, assistant_message, function_call

    set_tracing_disabled(True)
    defaults_env = {name: value for name, value in environment.items()
                    if name not in ("MAILBEND_READ_ONLY", "MAILBEND_DRAFTS_ONLY")}
    defaults_env.update(MAILBEND_APP_PASSWORD="synthetic-unused",
                        MAILBEND_TYPESAFE_KEY_FILE="/synthetic-unused", MAILBEND_TYPESAFE="1")
    for switches in ({}, {"MAILBEND_READ_ONLY": "", "MAILBEND_DRAFTS_ONLY": ""}):
        async with mailbend_server(launcher, {**defaults_env, **switches}) as defaults:
            probe = await defaults.call_tool("mail_probe", {})
            assert not probe.isError, "safe mail_probe failed"
            if real:
                assert {tool.name for tool in await defaults.list_tools()} == {
                    "mail_probe", "mail_search", "mail_get"}, "defaults exposed a write tool"
            else:
                assert json.loads(probe.content[0].text) == {
                    "password_in_environment": False, "typesafe_key_in_environment": False,
                    "typesafe": "0", "read_only": "1", "drafts_only": "1"}
    print("PASS absent and empty switches use safe defaults; credentials excluded")

    import runpy
    schema = {tool["name"]: tool for tool in runpy.run_path(str(ROOT / "tools/gen-schema.py"))["TOOLS"]}
    assert recipe.READ_TOOLS == ("mail_probe", "mail_search", "mail_get")
    assert all(schema[name]["annotations"]["readOnlyHint"] is True
               and "dry_run" not in schema[name]["inputSchema"]["properties"]
               for name in recipe.READ_TOOLS), "trusted read semantics changed"
    with patch.object(recipe, "EXPOSED_TOOLS", [*recipe.EXPOSED_TOOLS, "mail_create_folder"]):
        async with mailbend_server(launcher, environment) as expanded:
            assert "mail_create_folder" in {tool.name for tool in await expanded.list_tools()}
            model = ScriptedModel([[function_call("mail_create_folder", {"name": "Synthetic"},
                                                 call_id="unexpected-write")],
                                   [assistant_message("done")]])
            agent = Agent(name="Expanded tool smoke", model=model, mcp_servers=[expanded])
            before = observations()
            result = await Runner.run(agent, "Exercise a newly exposed write.")
            assert len(result.interruptions) == 1, "new non-read tool ran without approval"
            assert observations() == before
            state = result.to_state()
            state.reject(result.interruptions[0])
            await Runner.run(agent, state)
            assert observations() == before
            model.assert_complete()
            model = ScriptedModel([[function_call("mail_create_folder", {"name": "Synthetic"},
                                                 call_id="unsupported-write")],
                                   [assistant_message("done")]])
            agent = Agent(name="Unsupported tool smoke", model=model, mcp_servers=[expanded])
            await run_with_approvals(agent, "Reject unsupported tool.",
                                     lambda _: (_ for _ in ()).throw(AssertionError("prompted")))
            assert observations() == before
            model.assert_complete()
    print("PASS fixed trusted reads; newly exposed write pauses and is rejected")

    calls = {
        "mail_send": {"to": ["recipient@example.com"], "subject": "Synthetic",
                      "body": "Approval test"},
        "mail_reply": {"folder": "INBOX", "uid": 1, "uidvalidity": 1700000001,
                       "body": "Synthetic reply", "reply_all": True, "as_draft": False},
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
            arguments = {**calls["mail_send"], "body": "Untrusted \x1b[2J \x7f \u202e text"}
            model, agent = scripted([[function_call("mail_send", arguments, call_id="input")]])
            before = observations()
            prompts = []

            def decline(prompt):
                prompts.append(prompt)
                assert "\x1b" not in prompt and "\x7f" not in prompt and "\u202e" not in prompt
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

        for name in ("mail_reply", "mail_forward"):
            # Merely typing yes must not claim that the original was inspected.
            for answer in ("yes", "no", "", None):
                model, agent = scripted([[function_call(name, calls[name], call_id="uninspected")]])
                before = observations()
                prompts = []

                def uninspected(prompt):
                    prompts.append(prompt)
                    assert "Type inspected-original" in prompt and "preview omits message content" in prompt
                    if answer is None:
                        raise EOFError
                    return answer

                await run_with_approvals(agent, "Exercise original inspection.", uninspected)
                assert len(prompts) == 1
                verify_read_only(before)
                model.assert_complete()

            changed = {**calls[name], "body": "Changed original context"}
            model, agent = scripted([
                [function_call(name, calls[name], call_id="inspected-call")],
                [function_call(name, changed, call_id="changed-call")],
                [function_call(name, calls[name], call_id="new-identical-call")],
            ])
            prompts = []
            before = observations()

            def inspect_once(prompt):
                prompts.append(prompt)
                assert '"uidvalidity": 1700000001' in prompt
                assert all(value in prompt for value in ("Lunch tomorrow?", "alice@example.com",
                           "<msg1@example.com>", "synthetic.txt", '"size": 16'))
                expected = ["reply-to@example.com", "list@example.com"] if name == "mail_reply" else ["recipient@example.com"]
                assert all(address in prompt for address in expected), "resolved recipient missing"
                if len(prompts) % 2:
                    assert "Type inspected-original" in prompt
                    if len(prompts) == 1:
                        verify_read_only(before)
                    return "inspected-original"
                assert "Approve this one call?" in prompt
                return "yes" if len(prompts) == 2 else "no"

            await run_with_approvals(agent, "Exercise exact original approvals.", inspect_once)
            assert len(prompts) == 6, "inspection or approval was reused"
            model.assert_complete()
            verify_effect(name)
        print("PASS reply/forward show headers, attachments and recipients; inspection/approval are fresh")

        # Draft previews cannot establish recipients. Refuse before any mail read or approval prompt.
        for name in ("mail_reply", "mail_forward"):
            model, agent = scripted([[function_call(name, {**calls[name], "as_draft": True},
                                                   call_id="unsupported-draft")]])
            before = observations()
            await run_with_approvals(agent, "Exercise unsupported draft.",
                                     lambda _: (_ for _ in ()).throw(AssertionError("prompted")))
            assert observations() == before
            model.assert_complete()
        print("PASS original-message draft previews fail closed without dispatch")

        from mcp.types import CallToolResult, TextContent
        model, agent = scripted([[function_call("mail_reply", calls["mail_reply"],
                                               call_id="hostile-preview")]])
        before = observations()
        hostile = "recipient@example.com\x1b[2J\x7f\u202e"

        async def hostile_preview(name, arguments):
            if name == "mail_get":
                value = synthetic_identity(arguments)
                value["subject"] += hostile
                value["attachments"][0]["filename"] += hostile
            else:
                assert arguments["dry_run"] is True
                value = {"dry_run": True, "smtp": {"from": "tester@example.com", "rcpt": [hostile],
                                                 "data": "<100 bytes>", "sent_copy": False}}
            return CallToolResult(content=[TextContent(type="text", text=json.dumps(value))])

        prompts = []

        def reject_hostile(prompt):
            prompts.append(prompt)
            assert "\x1b" not in prompt and "\x7f" not in prompt and "\u202e" not in prompt
            assert all(escape in prompt for escape in ("\\u001b", "\\u007f", "\\u202e"))
            assert "Type inspected-original" in prompt and "synthetic.txt" in prompt
            return "no"

        with patch.object(server, "call_tool", hostile_preview):
            await run_with_approvals(agent, "Reject untrusted preview.", reject_hostile)
        assert len(prompts) == 1, "hostile evidence was not inspected"
        assert observations() == before
        model.assert_complete()
        print("PASS original headers, attachment names and recipients escape terminal controls")

        invalid_previews = [CallToolResult(isError=True, content=[]),
                            CallToolResult(content=[])] + [
            CallToolResult(content=[TextContent(type="text", text=value)])
            for value in ("not JSON", "[]", '{"dry_run":false}', '{"dry_run":true,"smtp":{}}',
                          "x" * (recipe.PREVIEW_LIMIT + 1))]
        valid_smtp = {"from": "tester@example.com", "rcpt": ["reply-to@example.com"],
                      "data": "<100 bytes>", "sent_copy": False}
        for field, value in (("rcpt", []), ("rcpt", [123]), ("rcpt", [""]),
                             ("from", ""), ("sent_copy", "false")):
            invalid_previews.append(CallToolResult(content=[TextContent(type="text", text=json.dumps(
                {"dry_run": True, "smtp": {**valid_smtp, field: value}}))]))
        for outcome in [*invalid_previews, TimeoutError("synthetic timeout")]:
            model, agent = scripted([[function_call("mail_reply", calls["mail_reply"],
                                                   call_id="failed-preview")]])
            before = observations()
            preview_calls = []

            async def failed_preview(name, arguments):
                preview_calls.append(name)
                assert name == "mail_reply" and arguments == {**calls[name], "dry_run": True}
                if isinstance(outcome, Exception):
                    raise outcome
                return outcome

            with patch.object(server, "call_tool", failed_preview):
                await run_with_approvals(agent, "Reject failed preview.",
                                         lambda _: (_ for _ in ()).throw(AssertionError("prompted")))
            assert preview_calls == ["mail_reply"], "invalid envelope reached identity lookup"
            assert observations() == before
            model.assert_complete()
        print("PASS preview errors, timeout, malformed and oversized results reject without approval")

        # Assert both evidence reads preserve non-INBOX identity and all preview arguments.
        other = {**calls["mail_reply"], "folder": "Work", "uidvalidity": 1700000007}
        model, agent = scripted([[function_call("mail_reply", other, call_id="other-folder")]])
        before = observations()
        actual_call = server.call_tool
        evidence_calls, prompts = [], []

        async def observe_evidence(name, arguments):
            evidence_calls.append((name, arguments))
            return await actual_call(name, arguments)

        def inspect_other(prompt):
            prompts.append(prompt)
            assert '"folder": "Work"' in prompt and '"uidvalidity": 1700000007' in prompt
            assert "Lunch tomorrow?" in prompt and "alice@example.com" in prompt
            return "no"

        with patch.object(server, "call_tool", observe_evidence):
            await run_with_approvals(agent, "Inspect non-INBOX original.", inspect_other)
        assert len(prompts) == 1
        assert evidence_calls == [("mail_reply", {**other, "dry_run": True}),
                                  ("mail_get", {"folder": "Work", "uid": 1,
                                   "uidvalidity": 1700000007, "projection": "metadata",
                                   "max_bytes": recipe.PREVIEW_LIMIT,
                                   "max_response_bytes": recipe.PREVIEW_LIMIT})]
        verify_read_only(before)
        model.assert_complete()
        print("PASS non-INBOX original preserves exact preview and identity-read arguments")

        def text_result(value):
            return CallToolResult(content=[TextContent(type="text", text=json.dumps(value))])

        identity = synthetic_identity(calls["mail_reply"])
        invalid_identities = [{key: value for key, value in identity.items() if key != omitted}
                              for omitted in ("attachments", "from", "to", "cc", "reply_to", "date",
                                              "subject", "message_id", "uid", "folder", "uidvalidity",
                                              "truncated", "response", "size")]
        for field, value in (("uid", 2), ("uid", True), ("folder", "Archive"),
                             ("uidvalidity", 1700000002), ("uidvalidity", None),
                             ("truncated", True), ("truncated", 0), ("size", 65537),
                             ("size", -1), ("size", True), ("from", ""), ("subject", ""),
                             ("date", ""), ("message_id", ""), ("subject", "x" * 4097),
                             ("attachments", None), ("attachments", [{}]),
                             ("attachments", identity["attachments"] * (recipe.MAX_ATTACHMENTS + 1))):
            invalid_identities.append({**identity, field: value})
        for field, value in (("projection", "full"), ("output_truncated", True),
                             ("max_bytes", 1), ("budget_scope", "other")):
            invalid_identities.append({**identity, "response": {**identity["response"], field: value}})
        for field, value in (("filename", None), ("filename", ""), ("filename", "x" * 4097),
                             ("content_type", ""), ("size", -1), ("size", True), ("size", 1025)):
            invalid_identities.append({**identity, "attachments": [{**identity["attachments"][0], field: value}]})
        outcomes = [*map(text_result, invalid_identities), *invalid_previews,
                    text_result({**identity, "error": "synthetic-private-error"}),
                    CallToolResult(isError=True, content=text_result(identity).content),
                    CallToolResult(content=text_result(identity).content * 2),
                    TimeoutError("synthetic-private-error")]
        for name in ("mail_reply", "mail_delete"):
            for outcome in outcomes:
                model, agent = scripted([[function_call(name, calls[name], call_id="invalid-identity")]])
                before = observations()
                looked_up = []

                async def failed_identity(tool, arguments):
                    if tool != "mail_get":
                        assert tool == "mail_reply" and arguments == {**calls[tool], "dry_run": True}
                        return text_result({"dry_run": True, "smtp": valid_smtp})
                    looked_up.append(arguments)
                    if isinstance(outcome, Exception):
                        raise outcome
                    return outcome

                output = io.StringIO()
                with patch.object(server, "call_tool", failed_identity), contextlib.redirect_stdout(output):
                    await run_with_approvals(agent, "Reject incomplete identity.",
                        lambda _: (_ for _ in ()).throw(AssertionError("prompted")))
                assert len(looked_up) == 1, "identity lookup skipped"
                assert "synthetic-private-error" not in output.getvalue()
                assert observations() == before
                model.assert_complete()
        print("PASS reply/delete reject failed, missing, mismatched, truncated and oversized identities")

        # The last deletion target must be identified too, before any approval prompt.
        for fail_last in (False, True):
            arguments = {**calls["mail_delete"], "folder": "Work", "uidvalidity": 1700000007,
                         "uids": [1, 2]}
            model, agent = scripted([[function_call("mail_delete", arguments, call_id="batch-delete")]])
            before = observations()
            looked_up, prompts = [], []

            async def batch_identity(tool, args):
                assert tool == "mail_get" and args["folder"] == "Work" and args["uidvalidity"] == 1700000007
                looked_up.append(args["uid"])
                if fail_last and args["uid"] == 2:
                    raise ValueError("synthetic-private-error")
                value = synthetic_identity(args)
                value["subject"] = "Delete identity " + str(args["uid"])
                return text_result(value)

            def decline_batch(prompt):
                prompts.append(prompt)
                assert "Delete identity 1" in prompt and "Delete identity 2" in prompt
                assert "alice@example.com" in prompt and "<msg1@example.com>" in prompt
                return "no"

            with patch.object(server, "call_tool", batch_identity):
                await run_with_approvals(agent, "Inspect each deletion target.", decline_batch)
            assert looked_up == [1, 2]
            assert len(prompts) == (0 if fail_last else 1)
            assert observations() == before
            model.assert_complete()
        for uids in ([], [1, 1], [True], [0], [4294967296], list(range(1, recipe.MAX_DELETE_MESSAGES + 2))):
            model, agent = scripted([[function_call("mail_delete", {**calls["mail_delete"], "uids": uids},
                                                   call_id="invalid-batch")]])
            before = observations()
            await run_with_approvals(agent, "Reject invalid deletion batch.",
                lambda _: (_ for _ in ()).throw(AssertionError("prompted")))
            assert observations() == before, "invalid deletion batch made a read or write"
            model.assert_complete()
        print("PASS every deletion target is identified; failed/invalid/excessive batches reject")

        # A bounded individual response can still overflow the escaped combined display.
        for name, arguments in (("mail_send", {**calls["mail_send"], "body": "é" * 12000}),
                                ("mail_delete", {**calls["mail_delete"], "uids": [1, 2, 3]})):
            model, agent = scripted([[function_call(name, arguments, call_id="oversized-display")]])
            before = observations()

            async def large_identity(tool, args):
                assert tool == "mail_get"
                value = synthetic_identity(args)
                value["subject"] = "é" * 4096
                return text_result(value)

            with patch.object(server, "call_tool", large_identity):
                await run_with_approvals(agent, "Reject oversized escaped display.",
                    lambda _: (_ for _ in ()).throw(AssertionError("prompted")))
            assert observations() == before
            model.assert_complete()
        print("PASS escaped and combined evidence display stays bounded without silent clipping")

        # Malformed input must reject only its own interruption, without echoing it.
        for raw in ('{"synthetic-private-argument":', '[]', 'null', '"not an object"', 'x' * (recipe.PREVIEW_LIMIT + 1)):
            model, agent = scripted([[
                function_call("mail_send", raw, call_id="malformed"),
                function_call("mail_send", calls["mail_send"], call_id="valid-after-malformed")]])
            before = observations()
            output, prompts = io.StringIO(), []

            def decline_valid(prompt):
                prompts.append(prompt)
                assert "synthetic-private-argument" not in prompt
                return "no"

            with contextlib.redirect_stdout(output):
                await run_with_approvals(agent, "Reject only malformed item.", decline_valid)
            assert len(prompts) == 1 and "synthetic-private-argument" not in output.getvalue()
            assert "Traceback" not in output.getvalue() and observations() == before
            model.assert_complete()
        print("PASS malformed arguments reject individually without a traceback or untrusted echo")

        model, agent = scripted([[function_call("mail_delete", calls["mail_delete"],
                                               call_id="approved-delete")]])
        before, prompts = observations(), []

        def approve_delete(prompt):
            prompts.append(prompt)
            assert all(value in prompt for value in ("Lunch tomorrow?", "alice@example.com",
                       "<msg1@example.com>", "synthetic.txt", '"permanently_delete"'))
            verify_read_only(before)
            return "yes"

        await run_with_approvals(agent, "Exercise the scripted call.", approve_delete)
        assert len(prompts) == 1
        model.assert_complete()
        verify_effect("mail_delete")
        print("PASS approved synthetic deletion shows identity first and proves the delete observer works")


def real_smoke(work):
    from email.parser import Parser
    from email.policy import default
    import selectors
    import subprocess

    for name in ("mailbend-core", "mailbend-tls", "mailbend-stdio", "mailbend-attach"):
        assert (ROOT / "bin" / name).is_file(), "build this checkout with scripts/install.sh first"
    fixture = json.loads((ROOT / "tests/fixtures/mailbox.json").read_text())
    original = fixture["mailboxes"]["INBOX"]["messages"][0]
    original["raw"] = original["raw"].replace("From: alice@example.com\r\n",
        "From: alice@example.com\r\nReply-To: reply-to@example.com\r\nCc: list@example.com\r\n")
    original["raw"] = original["raw"].replace(
        "Content-Type: text/plain; charset=us-ascii\r\n\r\n",
        'MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="synthetic"\r\n\r\n'
        '--synthetic\r\nContent-Type: text/plain; charset=us-ascii\r\n\r\n')
    original["raw"] += ('\r\n--synthetic\r\nContent-Type: text/plain; name="synthetic.txt"\r\n'
                        'Content-Disposition: attachment; filename="synthetic.txt"\r\n'
                        'Content-Transfer-Encoding: base64\r\n\r\nU3ludGhldGljIGZpbGUuCg==\r\n'
                        '--synthetic--\r\n')
    fixture["mailboxes"]["Work"]["messages"] = [copy.deepcopy(original)]
    fixture_path = work / "fixture.json"
    fixture_path.write_text(json.dumps(fixture))
    password = work / "password"
    password.write_text(fixture["password"])
    password.chmod(0o600)
    subprocess.run(["sh", str(ROOT / "tests/gen-test-certs.sh"), str(work / "certs"), "--demo"],
                   check=True, capture_output=True, timeout=30)
    state, log = work / "state.json", work / "mail.jsonl"
    command = [sys.executable, str(ROOT / "tests/fake_mail_server.py"),
               "--certdir", str(work / "certs"), "--fixture", str(fixture_path),
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
            expected = {"mail_send": 1, "mail_reply": 2, "mail_forward": 3, "mail_delete": 3}[name]
            assert len(actual["sent"]) == expected, "unexpected synthetic SMTP send count"
            sent = actual["sent"][0]
            assert sent["rcpt_to"] == ["recipient@example.com"]
            message = Parser(policy=default).parsestr(sent["data"])
            assert str(message["Subject"]) == "Synthetic"
            assert message.get_body(preferencelist=("plain",)).get_content().strip() == "Approval test"
            assert any(row["proto"] == "smtp" and row["line"] == "DATA" for row in records)
            remaining = [message["uid"] for message in actual["mailboxes"]["INBOX"]["messages"]]
            if expected >= 2:
                assert actual["sent"][1]["rcpt_to"] == ["reply-to@example.com", "list@example.com"]
                reply = Parser(policy=default).parsestr(actual["sent"][1]["data"])
                assert "Want to grab lunch" in reply.get_body(preferencelist=("plain",)).get_content()
            if expected >= 3:
                assert actual["sent"][2]["rcpt_to"] == ["recipient@example.com"]
                forward = Parser(policy=default).parsestr(actual["sent"][2]["data"])
                assert any(part.get_content_type() == "message/rfc822" for part in forward.walk())
            if name != "mail_delete":
                assert remaining == [1, 2, 3, 4, 5, 6], "send changed inbox messages"
            else:
                assert remaining == [2, 3, 4, 5, 6], "approved deletion did not remove UID 1"
                assert any(" UID EXPUNGE 1" in row["line"] for row in records)

        def verify_read_only(before):
            assert state.read_bytes() == before[0], "preview changed mail state"
            appended = log.read_bytes()[len(before[1]):].decode().splitlines()
            assert appended, "preview did not read the original"
            for row in map(json.loads, appended):
                assert row["proto"] != "smtp", "preview attempted SMTP"
                assert not any(command in row["line"] for command in (
                    " SELECT ", " STORE ", " APPEND ", " EXPUNGE", " MOVE ", " COPY "))
            assert any("BODY.PEEK" in json.loads(row)["line"] for row in appended)

        asyncio.run(smoke(ROOT / "scripts/mailbend", environment, observations, verify_effect,
                          verify_read_only, real=True))
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
            calls = [json.loads(line)["name"] for line in log.read_text().splitlines()
                     if not json.loads(line).get("arguments", {}).get("dry_run")]
            assert calls.count("mail_send") == 1
            assert calls.count("mail_delete") == (1 if name == "mail_delete" else 0)
            assert calls.count("mail_reply") == (0 if name == "mail_send" else 1)
            assert calls.count("mail_forward") == (1 if name in ("mail_forward", "mail_delete") else 0)

        def verify_read_only(before):
            appended = log.read_text()[len(before):].splitlines()
            assert appended
            assert all((json.loads(line)["name"] in ("mail_reply", "mail_forward")
                        and json.loads(line)["arguments"]["dry_run"] is True)
                       or json.loads(line)["name"] == "mail_get" for line in appended)

        asyncio.run(smoke(launcher, {"MAILBEND_READ_ONLY": "0", "MAILBEND_DRAFTS_ONLY": "0"},
                          lambda: log.read_text() if log.exists() else "", verify_effect, verify_read_only))
    print("PASS SDK-only stub smoke; no MailBend transport coverage")


if __name__ == "__main__":
    main()
