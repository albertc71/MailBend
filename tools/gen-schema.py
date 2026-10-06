#!/usr/bin/env python3
"""Generate src/schema.bend, the MCP tool list that tools/list returns.

Edit the TOOLS table below, then run: python3 tools/gen-schema.py
CI fails when the checked-in src/schema.bend differs from the output.

JSON object keys keep the order in which they are written here, so
reordering keys changes the generated text.
"""
import json
import re
from pathlib import Path

SCHEMA_FILE = Path(__file__).resolve().parent.parent / "src" / "schema.bend"


# Schema builders

def param(kind, description=None, **constraints):
    """One parameter schema: its JSON type, constraints, then description."""
    schema = {"type": kind, **constraints}
    if description is not None:
        schema["description"] = description
    return schema


def inputs(properties, required=()):
    """A tool's input schema: an object that admits only these properties."""
    return {"type": "object", "properties": properties,
            "required": list(required), "additionalProperties": False}


def hints(read_only=False, destructive=False, idempotent=False,
          open_world=False):
    """MCP tool annotations."""
    return {"readOnlyHint": read_only, "destructiveHint": destructive,
            "idempotentHint": idempotent, "openWorldHint": open_world}


def tool(name, description, annotations, properties=None, required=()):
    """One tools/list entry."""
    return {"name": name, "description": description,
            "inputSchema": inputs(properties or {}, required),
            "annotations": annotations}


# Annotations

READS = hints(read_only=True, idempotent=True)
SETS_FLAGS = hints(idempotent=True)
CHANGES = hints()
DELETES = hints(destructive=True)
SENDS = hints(open_world=True)


# Shared parameters

FOLDER = param("string", "Folder (IMAP mailbox) name. Default: INBOX.")
UID = param("integer", minimum=1)
UIDS = param(
    "array", "Message UIDs in the folder (from mail_search or mail_get_new).",
    items=UID, minItems=1)
UIDVALIDITY = param(
    "integer",
    "The folder's UIDVALIDITY returned with the UIDs (mail_search, mail_get, "
    "mail_get_new). Checked in the same session as the change; if the folder "
    "changed since, nothing is changed.",
    minimum=1)

# The messages a change applies to; the whole input of the simple changes.
MESSAGES = {"folder": FOLDER, "uids": UIDS, "uidvalidity": UIDVALIDITY}
MESSAGES_REQUIRED = ["uids", "uidvalidity"]

ADDRESSES = param(
    "array",
    "Addresses like name@example.com or \"Name <name@example.com>\".",
    items=param("string"))
# Written out, because its description comes before its items.
ATTACHMENTS = {
    "type": "array",
    "description":
        "Files to attach. Only regular files inside MAILBEND_ATTACH_DIR are "
        "allowed; attachments are off when it is not set.",
    "items": {
        "type": "object",
        "required": ["path"],
        "additionalProperties": False,
        "properties": {
            "path": param(
                "string",
                "A file in MAILBEND_ATTACH_DIR: relative to it, or absolute "
                "inside it (max 25 MB, no symlinks)."),
            "filename": param(
                "string",
                "Name shown to the recipient. Default: the file name."),
            "content_type": param(
                "string", "MIME type. Default: guessed from the extension."),
        },
    },
}
AS_DRAFT = param(
    "boolean",
    "Save to the resolved drafts folder instead of sending; preserves Bcc "
    "recipients.")

COMPOSE = {
    "to": ADDRESSES,
    "cc": ADDRESSES,
    "bcc": {**ADDRESSES,
            "description":
                "Blind copies: retained in saved drafts; sent messages "
                "include them only in the SMTP envelope."},
    "subject": param("string"),
    "body": param("string", "Plain-text body."),
    "in_reply_to": param(
        "string", "Message-ID this answers (sets In-Reply-To)."),
    "references": param("string", "References header value."),
    "attachments": ATTACHMENTS,
}

FLAG_COLOURS = ["red", "orange", "yellow", "green", "blue", "purple", "grey"]


# Shared description text

FLAGS_REPORTED = (
    "flags lists each changed UID's flags as the server reported them after "
    "the change (null if it reported none). ")
FLAG_PARTIAL = (
    "If the change stops once a store was acknowledged or sent unanswered (or "
    "the TLS helper is lost after starting), the call fails with partial: "
    "true, listing the acknowledged changes and those that may have run "
    "unanswered; a retry is idempotent but may fail again on a server that "
    "refuses the colour keywords. A change that stopped before any store "
    "could run, or whose UIDs none exist, is a plain error.")
SEND_RULES = (
    " A send is refused, and nothing is sent, when a recipient is not in "
    "MAILBEND_ALLOWED_RECIPIENTS or the MAILBEND_MAX_SENDS_PER_DAY limit is "
    "reached. With MAILBEND_SAVE_SENT the result's sent_copy says whether a "
    "copy was saved to the Sent folder; a failed copy does not fail the "
    "send.")
MOVE_CUT_OFF = (
    "If the move is cut off after the copy may have run, the call fails with "
    "partial: true and the messages may be in both folders, so check the "
    "destination before retrying.")


# The tool list, in tools/list order

TOOLS = [
    tool("mail_probe",
         "Check the connection: verified TLS login, server capabilities "
         "(IDLE, MOVE, UIDPLUS) and resolved special folders. Changes "
         "nothing.",
         READS),
    tool("mail_list_folders",
         "List all IMAP folders with their advertised special use (drafts, "
         "sent, trash, junk, archive). Changes nothing.",
         READS),
    tool("mail_search",
         "Search a folder, newest first. Opens the folder read-only, so "
         "nothing is marked read. All criteria are combined with AND.",
         READS,
         {"folder": FOLDER,
          "from": param("string"),
          "to": param("string"),
          "cc": param("string"),
          "subject": param("string"),
          "body": param("string", "Text in the body."),
          "text": param("string", "Text anywhere in headers or body."),
          "since": param("string", "On or after this date, YYYY-MM-DD."),
          "before": param("string", "Before this date, YYYY-MM-DD."),
          "unseen": param("boolean"),
          "seen": param("boolean"),
          "flagged": param("boolean"),
          "limit": param("integer", "Default 20.", minimum=1, maximum=200)}),
    tool("mail_get",
         "Read one message: headers, plain text (or text from HTML) and the "
         "attachment list. Uses BODY.PEEK on a read-only folder, so the "
         "message stays unread.",
         READS,
         {"folder": FOLDER,
          "uid": UID,
          "max_bytes": param(
              "integer",
              "Read at most this many bytes of the message. Default 262144.",
              minimum=1024, maximum=16777216)},
         ["uid"]),
    tool("mail_get_new",
         "List messages that arrived after a checkpoint (UIDVALIDITY + UID), "
         "oldest first. Pass back next_since_uid and uidvalidity on the next "
         "call. Does not use or change read/unread state.",
         READS,
         {"folder": FOLDER,
          "since_uid": param(
              "integer", "Last UID already processed. Default 0.", minimum=0),
          "uidvalidity": param(
              "integer",
              "UIDVALIDITY from the previous call; required when since_uid is "
              "set. If it changed, the checkpoint restarts at 0.",
              minimum=0),
          "limit": param("integer", "Default 50.", minimum=1, maximum=500)}),
    tool("mail_get_thread",
         "Read the conversation a message belongs to, oldest first (by "
         "INTERNALDATE, then UID): the messages in its folder, INBOX and "
         "the resolved Sent folder that are linked to it by Message-ID, "
         "In-Reply-To and References, each with its folder, uidvalidity and "
         "parent (the Message-ID of the message it answers in the thread, "
         "or null). Messages are never grouped by subject. Two rounds of "
         "linked IDs are searched, at most 50 IDs each, so a long thread "
         "can be cut short; searched lists the folders. Changes nothing: "
         "messages stay unread.",
         READS,
         {"folder": FOLDER, "uid": UID},
         ["uid"]),
    tool("mail_get_attachment",
         "Save one attachment of a message as a new file in "
         "MAILBEND_DOWNLOAD_DIR (downloads are off without it) and return its "
         "path. The message is read as mail_get reads it, so it stays "
         "unread; it must be at most 25 MB. The file name is the "
         "attachment's (or filename) without any directory, control or "
         "invisible format characters or leading dots. An existing file is "
         "never replaced: the call fails, so pass another filename. Not "
         "available in read-only mode.",
         CHANGES,
         {"folder": FOLDER,
          "uid": UID,
          "index": param(
              "integer",
              "The attachment's position in mail_get's attachments, from 0.",
              minimum=0),
          "filename": param(
              "string",
              "Name to save the file as. Default: the attachment's file "
              "name.")},
         ["uid", "index"]),
    tool("mail_mark_read",
         "Mark messages as read (add the \\Seen flag).",
         SETS_FLAGS, MESSAGES, MESSAGES_REQUIRED),
    tool("mail_mark_unread",
         "Mark messages as unread (remove the \\Seen flag).",
         SETS_FLAGS, MESSAGES, MESSAGES_REQUIRED),
    tool("mail_flag",
         "Flag messages (add \\Flagged). With a colour, also set exactly that "
         "Apple Mail colour's $MailFlagBit0-2 keywords and clear the others "
         "(red has none); without one, the current colour is kept. With a "
         "colour the result has colour_kept: true; false when a message shows "
         "other flags or PERMANENTFLAGS says a change lasts only for this "
         "session (colour_not_kept lists those UIDs); or \"unverified\" when "
         "the server sent no PERMANENTFLAGS or no flags for a message. "
         + FLAGS_REPORTED + FLAG_PARTIAL,
         SETS_FLAGS,
         {**MESSAGES,
          "colour": param(
              "string", "Flag colour. Omit it to keep the current colour.",
              enum=FLAG_COLOURS)},
         MESSAGES_REQUIRED),
    tool("mail_unflag",
         "Unflag messages: remove \\Flagged, then clear every colour keyword. "
         + FLAGS_REPORTED + FLAG_PARTIAL,
         SETS_FLAGS, MESSAGES, MESSAGES_REQUIRED),
    tool("mail_move",
         "Move messages to another IMAP folder. Uses UID MOVE, or copy + "
         "expunge of exactly these UIDs with UIDPLUS. " + MOVE_CUT_OFF,
         CHANGES,
         {"folder": FOLDER,
          "uids": UIDS,
          "destination": param("string", "Target folder name."),
          "uidvalidity": UIDVALIDITY},
         ["uids", "destination", "uidvalidity"]),
    tool("mail_label",
         "Label messages: move them into an existing label folder (create one "
         "with mail_create_folder). On iCloud a label is a folder, so a "
         "message has one label and exists once; mail_move back to INBOX "
         "removes it. Refuses INBOX, Drafts, Sent, Trash, Junk, Archive and "
         "the other role folders. " + MOVE_CUT_OFF,
         CHANGES,
         {"folder": FOLDER,
          "uids": UIDS,
          "label": param(
              "string", "Name of an existing folder to use as the label."),
          "uidvalidity": UIDVALIDITY},
         ["uids", "label", "uidvalidity"]),
    tool("mail_trash",
         "Move messages to the resolved trash folder (configured override, "
         "advertised special use, or unique conventional name). Recoverable; "
         "does not delete permanently. " + MOVE_CUT_OFF,
         CHANGES, MESSAGES, MESSAGES_REQUIRED),
    tool("mail_delete",
         "PERMANENTLY delete messages (\\Deleted + UID EXPUNGE of exactly "
         "these UIDs). Cannot be undone; prefer mail_trash. Requires confirm "
         "= \"permanently-delete\" and the folder's uidvalidity. The confirm "
         "word guards against mistakes; it is not the user's approval, so ask "
         "the user first.",
         DELETES,
         {**MESSAGES,
          "confirm": param("string", enum=["permanently-delete"])},
         ["uids", "uidvalidity", "confirm"]),
    tool("mail_create_folder",
         "Create a folder and subscribe to it (if only the subscription "
         "fails, the call succeeds with subscribed: false; do not retry); on "
         "iCloud a folder works as a label (see mail_label). The parent "
         "folder must already exist, the name must not be taken, and it "
         "cannot be INBOX, Drafts, Sent, Trash, Junk, Archive (by any usual "
         "name), a configured or advertised role folder, or inside one. The "
         "review folder \"To Delete\" may be created only at top level. There "
         "is no tool to delete a folder: do that in Apple Mail or iCloud.com.",
         CHANGES,
         {"name": param(
             "string",
             "The new folder's full name, levels separated by the server's "
             "delimiter (see mail_list_folders).")},
         ["name"]),
    tool("mail_rename_folder",
         "Rename a folder together with its subfolders, and move the "
         "subscriptions of the folder and of its subscribed subfolders to "
         "their new names. If only the subscriptions fail, the call succeeds "
         "with subscribed: false; do not retry. If the connection drops "
         "before the answer, the folder may have been renamed: list folders "
         "before retrying. The same name rules as mail_create_folder apply to "
         "the new name and to every subfolder's new path, and a folder that "
         "is or contains INBOX, Drafts, Sent, Trash, Junk, Archive or another "
         "role folder cannot be renamed.",
         CHANGES,
         {"from": param("string", "Current full folder name."),
          "to": param(
              "string",
              "New full folder name; its parent must already exist.")},
         ["from", "to"]),
    tool("mail_save_draft",
         "Compose a message and save it to the resolved drafts folder "
         "(configured override, advertised special use, or unique "
         "conventional name) without sending. Preserves Bcc recipients in the "
         "draft.",
         CHANGES, COMPOSE),
    tool("mail_send",
         "Compose and send a message over SMTP (STARTTLS, verified). From is "
         "MAILBEND_EMAIL." + SEND_RULES,
         SENDS, COMPOSE),
    tool("mail_reply",
         "Reply to a message (sets In-Reply-To/References, quotes the "
         "original). Sends unless as_draft is true. Only the first 256 KB of "
         "the original is read: the result reports quoted_original_truncated, "
         "quoted_bytes and original_bytes, and a truncated quote also says so "
         "in the text." + SEND_RULES,
         SENDS,
         {"folder": FOLDER,
          "uid": UID,
          "uidvalidity": UIDVALIDITY,
          "body": param("string"),
          "reply_all": param(
              "boolean", "Also answer the original To and Cc. Default false."),
          "bcc": ADDRESSES,
          "attachments": ATTACHMENTS,
          "as_draft": AS_DRAFT},
         ["uid", "uidvalidity", "body"]),
    tool("mail_forward",
         "Forward a message, attached whole as a .eml file. Sends unless "
         "as_draft is true." + SEND_RULES,
         SENDS,
         {"folder": FOLDER,
          "uid": UID,
          "uidvalidity": UIDVALIDITY,
          "to": ADDRESSES,
          "cc": ADDRESSES,
          "bcc": ADDRESSES,
          "body": param("string", "Note above the forwarded message."),
          "attachments": ATTACHMENTS,
          "as_draft": AS_DRAFT},
         ["uid", "uidvalidity", "to"]),
]


# Bend rendering

# Generated lines stay within the 80 columns Base keeps. A literal line is
# four spaces of indent, the quoted text and a comma.
LINE_WIDTH = 80
LITERAL_WIDTH = LINE_WIDTH - len('    "",')

HEADER = """\
# The MCP tool list that tools/list returns: each tool's name, description,
# input schema and annotations, as JSON text.
#
# Generated by tools/gen-schema.py; edit that file, not this one, then run
# python3 tools/gen-schema.py. Each tool's JSON is split into short literals,
# because one long literal overflows the Bend compiler's stack.

import Base
"""


def escaped(text):
    """Text as it reads inside a Bend string literal.

    json.dumps(ensure_ascii=True) leaves only printable ASCII, so a
    backslash and a double quote are the only characters to escape.
    """
    return text.replace("\\", "\\\\").replace('"', '\\"')


def split_word(word, width):
    """Split one word into pieces whose escaped text fits in width."""
    pieces, piece = [], ""
    for char in word:
        if piece and len(escaped(piece + char)) > width:
            pieces.append(piece)
            piece = ""
        piece += char
    return pieces + [piece]


def wrap(text, width):
    """Split text into pieces whose escaped text fits in width. Pieces break
    after a space or a comma, so words and JSON members stay whole where
    they fit. The pieces join back to text."""
    pieces, line = [], ""
    for word in re.split(r"(?<=[ ,])(?=[^ ,])", text):
        if len(escaped(line + word)) <= width:
            line += word
            continue
        if line:
            pieces.append(line)
        *full, line = split_word(word, width)
        pieces.extend(full)
    return pieces + [line] if line else pieces


def def_name(entry):
    return "tool_defs." + entry["name"]


def tool_def(entry):
    """A def returning one tool's JSON text."""
    text = json.dumps(entry, ensure_ascii=True, separators=(",", ":"))
    literals = ",\n    ".join(f'"{escaped(piece)}"'
                               for piece in wrap(text, LITERAL_WIDTH))
    return (f"def {def_name(entry)}() -> String:\n"
            "  String.concat([\n"
            f"    {literals}])\n")


def tool_list_def(tools):
    """The public def: every tool's JSON in one JSON array."""
    calls = ",\n    ".join(f"{def_name(entry)}()" for entry in tools)
    return ("# The tool list as one JSON array.\n"
            "def tool_defs() -> String:\n"
            '  "[" ++ String.join([\n'
            f'    {calls}], ",") ++ "]"\n')


def render(tools):
    """The whole src/schema.bend text."""
    defs = [tool_def(entry) for entry in tools] + [tool_list_def(tools)]
    return HEADER + "".join("\n" + d for d in defs)


def main():
    SCHEMA_FILE.write_text(render(TOOLS), encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
