"""Fail malformed synthetic transports without confusing them with tool refusals."""
import base64
import json


def transport_failure(kind, code, stdout, stderr, secrets):
    safe = stderr
    for secret in sorted(set(secrets), key=len, reverse=True):
        if secret:
            safe = safe.replace(secret, "<redacted>")
            safe = safe.replace(base64.b64encode(secret.encode()).decode(), "<redacted>")
    detail = {"harness_failure": kind, "exit_code": code,
              "stdout_bytes": None if stdout is None else len(stdout.encode("utf-8", "replace")),
              "stderr": safe[:2048], "stderr_truncated": len(safe) > 2048}
    raise RuntimeError(json.dumps(detail, sort_keys=True)) from None


def cli_value(stdout, code, stderr, secrets):
    try:
        value = json.loads(stdout.strip().split("\n")[-1])
    except (ValueError, IndexError):
        transport_failure("cli output", code, stdout, stderr, secrets)
    if not isinstance(value, dict):
        transport_failure("cli output shape", code, stdout, stderr, secrets)
    return value


def mcp_tool(replies, code, stderr, secrets, *, stdout=None):
    try:
        reply = replies[-1]
        result = reply["result"]
        content = result["content"]
        if (reply["jsonrpc"] != "2.0" or type(reply["id"]) is not int or reply["id"] != 1
                or type(result["isError"]) is not bool or not isinstance(content, list)
                or not content or content[0]["type"] != "text"
                or not isinstance(content[0]["text"], str)
                or not isinstance(json.loads(content[0]["text"]), dict)):
            raise ValueError("tool reply shape")
    except (IndexError, KeyError, TypeError, ValueError):
        transport_failure("mcp tool reply", code, stdout, stderr, secrets)
    return result
