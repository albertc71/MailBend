#!/usr/bin/env python3
"""Writes src/schema.bend: the MCP tool list as one JSON string literal.

Edit the TOOLS table below, then run: python3 tools/gen-schema.py
"""
import json, pathlib

UIDS = {"type": "array", "items": {"type": "integer", "minimum": 1}, "minItems": 1,
        "description": "Message UIDs in the folder (from mail_search or mail_get_new)."}
FOLDER = {"type": "string", "description": "Folder (IMAP mailbox) name. Default: INBOX."}
ADDRS = {"type": "array", "items": {"type": "string"},
         "description": "Addresses like name@example.com or \"Name <name@example.com>\"."}
UIDV = {"type": "integer", "minimum": 1,
        "description": "The folder's UIDVALIDITY returned with the UIDs (mail_search, mail_get, mail_get_new). Checked in the same session as the change; if the folder changed since, nothing is changed."}
ATTS = {"type": "array", "description": "Files to attach. Only regular files inside MAILBEND_ATTACH_DIR are allowed; attachments are off when it is not set.",
        "items": {"type": "object", "required": ["path"], "additionalProperties": False, "properties": {
            "path": {"type": "string", "description": "A file in MAILBEND_ATTACH_DIR: relative to it, or absolute inside it (max 25 MB, no symlinks)."},
            "filename": {"type": "string", "description": "Name shown to the recipient. Default: the file name."},
            "content_type": {"type": "string", "description": "MIME type. Default: guessed from the extension."}}}}

def obj(props, required=()):
    return {"type": "object", "properties": props, "required": list(required), "additionalProperties": False}

def ann(read_only, destructive=False, idempotent=False, open_world=False):
    return {"readOnlyHint": read_only, "destructiveHint": destructive,
            "idempotentHint": idempotent, "openWorldHint": open_world}

READ = ann(True, idempotent=True)
COMPOSE = {"to": ADDRS, "cc": ADDRS, "bcc": {**ADDRS, "description": "Blind copies: only in the SMTP envelope, never in the message."},
           "subject": {"type": "string"}, "body": {"type": "string", "description": "Plain-text body."},
           "in_reply_to": {"type": "string", "description": "Message-ID this answers (sets In-Reply-To)."},
           "references": {"type": "string", "description": "References header value."},
           "attachments": ATTS}

TOOLS = [
    ("mail_probe", "Check the connection: verified TLS login, server capabilities (IDLE, MOVE, UIDPLUS) and special folders. Changes nothing.",
     obj({}), READ),
    ("mail_list_folders", "List all folders (iCloud's equivalent of labels) with their special use (drafts, sent, trash, junk, archive). Changes nothing.",
     obj({}), READ),
    ("mail_search", "Search a folder, newest first. Opens the folder read-only, so nothing is marked read. All criteria are combined with AND.",
     obj({"folder": FOLDER, "from": {"type": "string"}, "to": {"type": "string"}, "cc": {"type": "string"},
          "subject": {"type": "string"}, "body": {"type": "string", "description": "Text in the body."},
          "text": {"type": "string", "description": "Text anywhere in headers or body."},
          "since": {"type": "string", "description": "On or after this date, YYYY-MM-DD."},
          "before": {"type": "string", "description": "Before this date, YYYY-MM-DD."},
          "unseen": {"type": "boolean"}, "seen": {"type": "boolean"}, "flagged": {"type": "boolean"},
          "limit": {"type": "integer", "minimum": 1, "maximum": 200, "description": "Default 20."}}), READ),
    ("mail_get", "Read one message: headers, plain text (or text from HTML) and the attachment list. Uses BODY.PEEK on a read-only folder, so the message stays unread.",
     obj({"folder": FOLDER, "uid": {"type": "integer", "minimum": 1},
          "max_bytes": {"type": "integer", "minimum": 1024, "maximum": 16777216, "description": "Read at most this many bytes of the message. Default 262144."}},
         ["uid"]), READ),
    ("mail_get_new", "List messages that arrived after a checkpoint (UIDVALIDITY + UID), oldest first. Pass back next_since_uid and uidvalidity on the next call. Does not use or change read/unread state.",
     obj({"folder": FOLDER, "since_uid": {"type": "integer", "minimum": 0, "description": "Last UID already processed. Default 0."},
          "uidvalidity": {"type": "integer", "minimum": 0, "description": "UIDVALIDITY from the previous call; required when since_uid is set. If it changed, the checkpoint restarts at 0."},
          "limit": {"type": "integer", "minimum": 1, "maximum": 500, "description": "Default 50."}}), READ),
    ("mail_mark_read", "Mark messages as read (add the \\Seen flag).",
     obj({"folder": FOLDER, "uids": UIDS, "uidvalidity": UIDV}, ["uids", "uidvalidity"]), ann(False, idempotent=True)),
    ("mail_mark_unread", "Mark messages as unread (remove the \\Seen flag).",
     obj({"folder": FOLDER, "uids": UIDS, "uidvalidity": UIDV}, ["uids", "uidvalidity"]), ann(False, idempotent=True)),
    ("mail_move", "Move messages to another folder (apply a 'label'). Uses UID MOVE, or copy + expunge of exactly these UIDs with UIDPLUS.",
     obj({"folder": FOLDER, "uids": UIDS, "destination": {"type": "string", "description": "Target folder name."}, "uidvalidity": UIDV},
         ["uids", "destination", "uidvalidity"]), ann(False)),
    ("mail_trash", "Move messages to the Trash folder (found by its special use). Recoverable; does not delete permanently.",
     obj({"folder": FOLDER, "uids": UIDS, "uidvalidity": UIDV}, ["uids", "uidvalidity"]), ann(False)),
    ("mail_delete", "PERMANENTLY delete messages (\\Deleted + UID EXPUNGE of exactly these UIDs). Cannot be undone; prefer mail_trash. Requires confirm = \"permanently-delete\" and the folder's uidvalidity.",
     obj({"folder": FOLDER, "uids": UIDS, "uidvalidity": UIDV, "confirm": {"type": "string", "enum": ["permanently-delete"]}},
         ["uids", "uidvalidity", "confirm"]), ann(False, destructive=True)),
    ("mail_save_draft", "Compose a message and save it to the Drafts folder without sending.",
     obj(COMPOSE), ann(False)),
    ("mail_send", "Compose and send a message over SMTP (STARTTLS, verified). From is MAILBEND_EMAIL.",
     obj(COMPOSE), ann(False, open_world=True)),
    ("mail_reply", "Reply to a message (sets In-Reply-To/References, quotes the original). Sends unless as_draft is true. Only the first 256 KB of the original is read: the result reports quoted_original_truncated, quoted_bytes and original_bytes, and a truncated quote also says so in the text.",
     obj({"folder": FOLDER, "uid": {"type": "integer", "minimum": 1}, "uidvalidity": UIDV, "body": {"type": "string"},
          "reply_all": {"type": "boolean", "description": "Also answer the original To and Cc. Default false."},
          "bcc": ADDRS, "attachments": ATTS, "as_draft": {"type": "boolean", "description": "Save to Drafts instead of sending."}},
         ["uid", "uidvalidity", "body"]), ann(False, open_world=True)),
    ("mail_forward", "Forward a message, attached whole as a .eml file. Sends unless as_draft is true.",
     obj({"folder": FOLDER, "uid": {"type": "integer", "minimum": 1}, "uidvalidity": UIDV, "to": ADDRS, "cc": ADDRS, "bcc": ADDRS,
          "body": {"type": "string", "description": "Note above the forwarded message."}, "attachments": ATTS,
          "as_draft": {"type": "boolean", "description": "Save to Drafts instead of sending."}},
         ["uid", "uidvalidity", "to"]), ann(False, open_world=True)),
]

tools = [{"name": n, "description": d, "inputSchema": s, "annotations": a} for n, d, s, a in TOOLS]
text = json.dumps(tools, ensure_ascii=True, separators=(",", ":"))
# Bend expands a string literal into one nested term, so a long literal
# overflows the compiler's stack: emit short pieces and concatenate them.
def lit(piece):
    return '"' + piece.replace("\\", "\\\\").replace('"', '\\"') + '"'
pieces = [text[i:i + 96] for i in range(0, len(text), 96)]
body = ",\n    ".join(lit(p) for p in pieces)
root = pathlib.Path(__file__).resolve().parent.parent
(root / "src" / "schema.bend").write_text(
    "import Base\n\n"
    "# The MCP tool list (names, descriptions, input schemas, annotations).\n"
    "# Generated by tools/gen-schema.py; edit that file, not this one.\n"
    "def tool_defs() -> String:\n"
    f"  String.concat([\n    {body}])\n")
