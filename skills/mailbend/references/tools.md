# Tool reference

Names and input arguments below match the repository schema. These are not
complete schemas or permission grants. Use current advertised tool definitions
for types, required fields and bounds. Configured switches may hide tools.
[Tool effects](https://github.com/albertc71/MailBend/blob/main/README.md#what-it-can-do).

Each signature scopes arguments to its tool; a name valid for one tool need
not be valid for another. Read operations do not change read flags. File saves, drafts
and flag changes are writes too.
[Read and write safety](https://github.com/albertc71/MailBend/blob/main/README.md#safety).

- `mail_probe()`: Check connection, capabilities and role folders.
- `mail_list_folders()`: List existing folders and special-use attributes.
- `mail_search(folder, from, to, cc, subject, body, text, since, before, unseen, seen, flagged, cursor, limit, projection, max_response_bytes)`: Search and page summaries, newest first.
- `mail_get(folder, uid, uidvalidity, section, max_bytes, nested_message, projection, max_response_bytes)`: Read one message or a listed MIME part. `nested_message=true` requires a numeric message section and positive uidvalidity.
- `mail_get_new(folder, start, since_uid, uidvalidity, limit, projection, max_response_bytes)`: Read arrivals after a mailbox checkpoint.
- `mail_brief(folder, since_uid, uidvalidity, continuation, limit, projection, max_response_bytes)`: Read bounded deterministic metadata groups. Resume a capped unseen page with its returned continuation token; arrival cursors retain their existing meaning.
- `mail_refresh(folder, uids, uidvalidity)`: Refresh flags and presence of known UIDs.
- `mail_get_thread(folder, uid, uidvalidity, projection, max_response_bytes)`: Read a message-ID-linked conversation.
- `mail_awaiting_reply(window_days, min_age_days, limit, exclude_lists, exclude_automated)`: Report replied, awaiting and unknown states for bounded Sent candidates.
- `mail_contacts(query, window_days, limit)`: Find bounded stored-Sent contact candidates.
- `mail_correspondents(addresses, window_days, limit)`: Count bounded stored-header observations for exact addresses.
- `mail_classify(folder, uids, uidvalidity, candidates)`: Ask Jev for classifications without filing.
- `mail_triage(folder, uids, uidvalidity, dry_run)`: Apply Jev filing to existing folders.
- `mail_get_attachment(folder, uid, uidvalidity, section, index, filename, dry_run)`: Save one attachment as a new file.
- `mail_mark_read(folder, uids, uidvalidity, dry_run)`: Add the read flag.
- `mail_mark_unread(folder, uids, uidvalidity, dry_run)`: Remove the read flag.
- `mail_flag(folder, uids, uidvalidity, colour, dry_run)`: Add a flag or Apple Mail colour.
- `mail_unflag(folder, uids, uidvalidity, dry_run)`: Remove flag and colour.
- `mail_move(folder, uids, destination, uidvalidity, dry_run)`: Move messages to an existing folder.
- `mail_label(folder, uids, label, uidvalidity, dry_run)`: Move messages to an existing label folder.
- `mail_trash(folder, uids, uidvalidity, dry_run)`: Move messages to the resolved Trash folder.
- `mail_delete(folder, uids, uidvalidity, confirm, dry_run)`: Permanently delete only explicitly approved messages.
- `mail_create_folder(name, dry_run)`: Create and subscribe to an explicitly named folder.
- `mail_rename_folder(from, to, dry_run)`: Rename a folder and its subfolders.
- `mail_save_draft(to, cc, bcc, subject, body, in_reply_to, references, attachments, dry_run)`: Save a newly composed draft.
- `mail_send(to, cc, bcc, subject, body, in_reply_to, references, attachments, dry_run)`: Send approved content to approved recipients.
- `mail_reply(folder, uid, uidvalidity, body, reply_all, mark_answered, bcc, attachments, as_draft, dry_run)`: Reply or reply-all; use as_draft for a draft. Optional mark_answered adds \Answered to the original only after SMTP accepts the reply. A failed or unverified mark never permits resending.
- `mail_forward(folder, uid, uidvalidity, to, cc, bcc, body, attachments, as_draft, dry_run)`: Forward with original attached; use as_draft for a draft.

For a permanent-delete request, consult the advertised confirmation requirement
only after the user approves that operation. This reference intentionally does
not provide the confirmation word.
[Deletion safety](https://github.com/albertc71/MailBend/blob/main/README.md#safety).
