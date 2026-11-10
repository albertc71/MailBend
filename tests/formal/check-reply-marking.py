#!/usr/bin/env python3
"""Require production transition and evidence mutants to fail their named laws."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MUTATIONS = (
    ("marking defaults on", 'Policy.bool_arg(args, "mark_answered", False{})',
     'Policy.bool_arg(args, "mark_answered", True{})', 'original_mark_defaults_off'),
    ("drafts may mark", 'Bool.not(Policy.bool_arg(args, "as_draft", False{})) && Bool.not(dry_arg(args))',
     'True{} && Bool.not(dry_arg(args))', 'original_mark_drafts_skip'),
    ("dry runs may mark", '&& Bool.not(dry_arg(args)),\n    Some{Original',
     ',\n    Some{Original', 'original_mark_dry_runs_skip'),
    ("forwards may mark", 'reply && Policy.bool_arg(args, "mark_answered", False{})',
     'True{} && Policy.bool_arg(args, "mark_answered", False{})', 'original_mark_forwards_skip'),
    ("all successful outputs mark", 'String.eq(Policy.str_arg(j, "smtp_outcome", ""), "accepted") &&',
     'True{} &&', 'original_mark_unaccepted_skips'),
    ("accepted replies never mark", 'String.eq(Policy.str_arg(j, "smtp_outcome", ""), "accepted") &&',
     'False{} &&', 'original_mark_accepted_runs'),
    ('accepted evidence bypasses sent false', 'Policy.bool_arg(j, "sent", False{}), Policy.Ok{j}, original)',
     'True{}, Policy.Ok{j}, original)', 'original_mark_sent_false_skips'),
    ('absent Answered reported marked', 'OriginalNotMarked{"answered_absent"})',
     'OriginalMarked{})', 'original_mark_flag_examples'),
    ('present Answered never reported marked', 'Bool.pick(OriginalMark, I.has_attr(fs, "\\\\Answered"), OriginalMarked{},',
     'Bool.pick(OriginalMark, I.has_attr(fs, "\\\\Answered"), OriginalUnverified{"mark_unverified"},', 'original_mark_flag_examples'),
    ('changed UIDVALIDITY ignored', 'Bool.pick(String, U32.is_eq(n, want), "", "identity_changed")',
     'Bool.pick(String, U32.is_eq(n, want), "", "")', 'original_mark_flag_examples'),
    ('incomplete readback treated complete', 'case False{}:\n      OriginalUnverified{"mark_unverified"}\n\ndef original_mark.identity',
     'case False{}:\n      original_mark.flags(last_flags(refresh_flags(I.replies(lines, 4)), uid, None{}))\n\ndef original_mark.identity', 'original_mark_incomplete_readback_unverified'),
    ('transcript completeness guard bypassed', 'original_mark.readback(ok_at(lines, 1) && ok_at(lines, 2) && ok_at(lines, 3) &&\n        ok_at(lines, 4) && uidv_is(I.ok_code(I.replies(lines, 1), "UIDVALIDITY"), uidv), lines, uid)',
     'original_mark.readback(True{}, lines, uid)', 'original_mark_incomplete_transcript_unverified'),
    ('missing flags reported definitively absent', 'case None{}:\n      OriginalUnverified{"original_not_observed"}',
     'case None{}:\n      OriginalNotMarked{"answered_absent"}', 'original_mark_missing_flags_unverified'),
    ('transcript refusal reported marked', 'case SCon{h, t}:\n      OriginalNotMarked{SCon{h, t}}',
     'case SCon{h, t}:\n      OriginalMarked{}', 'original_mark_refused_transcript_not_marked'),
    ('result wrapper always unverified', 'original_mark.transcript(original_mark.refusal(lines, uidv), lines, uid, uidv)', 'OriginalUnverified{"mark_unverified"}', 'original_mark_result_fields_examples'),
    ('result wrapper always marked', 'original_mark.transcript(original_mark.refusal(lines, uidv), lines, uid, uidv)', 'OriginalMarked{}', 'original_mark_result_fields_examples'),
    ('marked result serialized false', '[J.kv("original_marked", J.bool(True{})),\n       J.kv("original_mark_reason", J.str("answered_observed"))]', '[J.kv("original_marked", J.bool(False{})),\n       J.kv("original_mark_reason", J.str("answered_observed"))]', 'original_mark_result_fields_examples'),
    ('not-marked result serialized true', '[J.kv("original_marked", J.bool(False{})), J.kv("original_mark_reason", J.str(reason))]', '[J.kv("original_marked", J.bool(True{})), J.kv("original_mark_reason", J.str(reason))]', 'original_mark_result_fields_examples'),
    ('unverified result serialized false', '[J.kv("original_marked", J.str("unverified")), J.kv("original_mark_reason", J.str(reason))]', '[J.kv("original_marked", J.bool(False{})), J.kv("original_mark_reason", J.str(reason))]', 'original_mark_result_fields_examples'),
    ('refusal omits identity check', 'original_mark.identity(positive(I.ok_code(I.replies(lines, 1), "UIDVALIDITY")), uidv), "")', '"", "")', 'original_mark_refusal_identity_examples'),
    ('result ignores refusal', 'original_mark.transcript(original_mark.refusal(lines, uidv), lines, uid, uidv)', 'original_mark.transcript("", lines, uid, uidv)', 'original_mark_result_fields_examples'),
    ('search refusal reason omitted', 'Bool.pick(String, I.refused(lines, 2), "search_refused", "")',
     'Bool.pick(String, I.refused(lines, 2), "", "")', 'original_mark_search_refusal_fields_example'),
    ('store refusal reason omitted', 'Bool.pick(String, I.refused(lines, 3), "store_refused", "")',
     'Bool.pick(String, I.refused(lines, 3), "", "")', 'original_mark_store_refusal_fields_example'),
)


def check(root):
    return subprocess.run(['bend', 'tests/formal/tool-laws.bend', '--check-only'],
                          cwd=root, capture_output=True, text=True, timeout=300,
                          env=dict(os.environ, BEND_NO_TELEMETRY='1'))


def passing(root, label):
    result = check(root)
    assert result.returncode == 0 and 'ALL PROOFS CHECK' in result.stdout, (label, result.stdout, result.stderr)
    print(f'PASS {label}', flush=True)


def main():
    original = (ROOT / 'src/tools.bend').read_text()
    passing(ROOT, 'checkout reply-marking laws')
    with tempfile.TemporaryDirectory(prefix='mailbend-reply-marking-') as directory:
        root = Path(directory)
        shutil.copytree(ROOT / 'src', root / 'src')
        shutil.copytree(ROOT / 'tests/formal', root / 'tests/formal',
                        ignore=shutil.ignore_patterns('__pycache__'))
        passing(root, 'copied reply-marking laws')
        target = root / 'src/tools.bend'
        for label, before, after, law in MUTATIONS:
            assert original.count(before) == 1, (label, 'target is not unique')
            target.write_text(original.replace(before, after))
            result = check(root)
            output = result.stdout + result.stderr
            location = re.search(r'^Location: (\S+)', output, re.MULTILINE)
            assert (result.returncode != 0 and 'SOME PROOFS FAIL' in output
                    and location is not None and location.group(1) == law
                    and re.search(r'^- expected\s*:', output, re.MULTILINE)
                    and re.search(r'^- observed\s*:', output, re.MULTILINE)), (label, law, output)
            print(f'PASS rejected {label}: {law}', flush=True)
            target.write_text(original)
        passing(root, 'restored reply-marking laws')
    assert (ROOT / 'src/tools.bend').read_text() == original, 'checkout changed'
    print('PASS checkout unchanged', flush=True)


if __name__ == '__main__':
    main()
