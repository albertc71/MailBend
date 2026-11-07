#!/usr/bin/env bash
# Transport tests: mailbend-tls's security and framing behavior, driven
# against tests/fake_mail_server.py over verified TLS. Prints PASS/FAIL per
# case and a summary; exits non-zero if any case failed.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/mailbox.json"
HELPER="$ROOT/bin/mailbend-tls"
WORK="$ROOT/build/test-transport-$$"
mkdir -p "$WORK"

PASS_COUNT=0
FAIL_COUNT=0
SERVER_PIDS=""
GLOBAL_LEAK=0
CASE1_LOG=""
CASE12_LOG=""

cleanup() {
  for p in $SERVER_PIDS; do
    kill "$p" >/dev/null 2>&1
  done
  for p in $SERVER_PIDS; do
    wait "$p" 2>/dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL $1 -- $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# --- build the helper -------------------------------------------------
mkdir -p "$ROOT/bin"
if ! { (cd "$ROOT/native" && "${CARGO:-cargo}" build --release --locked --quiet -p mailbend-tls -p mailbend-typesafe) \
       && cp "$ROOT/native/target/release/mailbend-tls" "$HELPER" \
       && cp "$ROOT/native/target/release/mailbend-typesafe" "$ROOT/bin/mailbend-typesafe"; } 2>"$WORK/build.err"; then
  echo "FAIL build -- $(cat "$WORK/build.err")"
  exit 1
fi

FIXTURE_USER=$(python3 -c "import json; print(json.load(open('$FIXTURE', encoding='utf-8'))['user'])")
PASSWORD=$(python3 -c "import json; print(json.load(open('$FIXTURE', encoding='utf-8'))['password'])")

CERTDIR="$WORK/certs"
if ! sh "$ROOT/tests/gen-test-certs.sh" "$CERTDIR" >"$WORK/certgen.err" 2>&1; then
  echo "FAIL certgen -- $(cat "$WORK/certgen.err")"
  exit 1
fi

# --- server lifecycle ---------------------------------------------------

# start_server NAME [fake_mail_server.py args...]
# Sets IMAP_PORT, SMTP_PORT, SILENT_PORT (may be empty), SRV_PID, STATE_FILE,
# LOG_FILE. Returns 1 (and prints nothing to stdout) if the server failed to
# come up within 5s.
start_server() {
  local name="$1" dir line kv n
  shift
  dir="$WORK/$name"
  mkdir -p "$dir"
  STATE_FILE="$dir/state.json"
  LOG_FILE="$dir/log.jsonl"
  python3 "$ROOT/tests/fake_mail_server.py" --certdir "$CERTDIR" --fixture "$FIXTURE" \
    --state "$STATE_FILE" --log "$LOG_FILE" "$@" \
    >"$dir/ready.txt" 2>"$dir/server.err" &
  SRV_PID=$!
  SERVER_PIDS="$SERVER_PIDS $SRV_PID"
  n=0
  while [ ! -s "$dir/ready.txt" ] && [ "$n" -lt 50 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  line="$(head -n 1 "$dir/ready.txt" 2>/dev/null)"
  case "$line" in
    READY*) ;;
    *)
      echo "server '$name' failed to start: $(cat "$dir/server.err" 2>/dev/null)" >&2
      return 1
      ;;
  esac
  IMAP_PORT=""; SMTP_PORT=""; SILENT_PORT=""
  for kv in $line; do
    case "$kv" in
      imap=*) IMAP_PORT="${kv#imap=}" ;;
      smtp=*) SMTP_PORT="${kv#smtp=}" ;;
      silent=*) SILENT_PORT="${kv#silent=}" ;;
    esac
  done
}

stop_server() {
  kill "$SRV_PID" >/dev/null 2>&1
  wait "$SRV_PID" 2>/dev/null
  SERVER_PIDS="$(printf '%s\n' $SERVER_PIDS | grep -v -x "$SRV_PID" | tr '\n' ' ')"
}

# --- helper invocation ---------------------------------------------------

# call_helper PROTOCOL SCRIPT_TEXT [ENV_ASSIGNMENT...]
# Runs the helper with the command script on stdin. Sets OUT (path), ERR
# (path), CODE (exit status), and tracks password leaks. Protocol-specific
# defaults precede caller overrides, so failure cases can replace them.
call_helper() {
  local protocol="$1" script="$2" password="$PASSWORD" email="$FIXTURE_USER" login="" assignment
  local -a deadline=()
  shift 2
  # env uses the last assignment, including negative cases that replace the
  # fixture password. Inspect that actual input without printing it.
  for assignment in "$@"; do
    case "$assignment" in
      MAILBEND_APP_PASSWORD=*) password="${assignment#*=}" ;;
      MAILBEND_EMAIL=*) email="${assignment#*=}" ;;
      MAILBEND_LOGIN=*) login="${assignment#*=}" ;;
    esac
  done
  # Keep the outer deadline in this wrapper so timeout cases are checked too.
  if [ -n "${HELPER_TIMEOUT_S:-}" ]; then deadline=(timeout "$HELPER_TIMEOUT_S"); fi
  printf '%s' "$script" >"$WORK/in.txt"
  OUT="$WORK/out.bin"; ERR="$WORK/err.txt"
  "${deadline[@]}" env -u MAILBEND_SMTP_TLS_MODE -u MAILBEND_LOGIN MAILBEND_EMAIL="$FIXTURE_USER" MAILBEND_APP_PASSWORD="$PASSWORD" \
      MAILBEND_CA_FILE="$CERTDIR/ca.pem" MAILBEND_TIMEOUT_MS="${TIMEOUT_MS:-5000}" \
      "$@" "$HELPER" "$protocol" <"$WORK/in.txt" >"$OUT" 2>"$ERR"
  CODE=$?
  check_leak "$password" "${login:-$email}"
}

# call_imap SCRIPT_TEXT [ENV_ASSIGNMENT...]
call_imap() {
  local script="$1"
  shift
  call_helper imap "$script" MAILBEND_IMAP_HOST=localhost \
      MAILBEND_IMAP_PORT="$IMAP_PORT" "$@"
}

# call_smtp SCRIPT_TEXT [ENV_ASSIGNMENT...]
call_smtp() {
  local script="$1"
  shift
  call_helper smtp "$script" MAILBEND_SMTP_HOST=localhost \
      MAILBEND_SMTP_PORT="$SMTP_PORT" "$@"
}

check_leak() {
  local password="$1" login="$2" encoded_password encoded_plain
  # An empty password has no secret bytes. Match literal bytes, including
  # SMTP's LOGIN password and PLAIN NUL-user-NUL-password encodings.
  [ -n "$password" ] || return 0
  encoded_password=$(printf '%s' "$password" | base64 | tr -d '\n') || return 1
  encoded_plain=$(printf '\0%s\0%s' "$login" "$password" | base64 | tr -d '\n') || return 1
  if grep -aFq -e "$password" -e "$encoded_password" -e "$encoded_plain" -- "$OUT" "$ERR"; then
    GLOBAL_LEAK=1
    return 1
  fi
  return 0
}

# Negative controls for the checker itself. Python independently encodes
# synthetic output; it does not reuse the checker's base64 implementation.
# Shadow the aggregate so intentional leaks cannot poison later cases.
case_password_leak_check() {
  local GLOBAL_LEAK=0 PASSWORD="fixture-synthetic-password"
  local HELPER="$WORK/synthetic-leak-helper" OUT ERR CODE
  local password identity form stream expected status ok=1
  local -a identity_env=()
  cat >"$HELPER" <<'PY'
#!/usr/bin/env python3
import base64
import os
import sys

password = os.environb[b'MAILBEND_APP_PASSWORD']
login = os.environb.get(b'MAILBEND_LOGIN') or os.environb[b'MAILBEND_EMAIL']
stream = os.environ['SYNTHETIC_LEAK_STREAM']
if stream == 'superseded':
    password = b'overridden-synthetic-password'
form = os.environ['SYNTHETIC_LEAK_FORM']
if form == 'login':
    output = base64.b64encode(password)
elif form == 'plain':
    output = base64.b64encode(b'\0' + login + b'\0' + password)
else:
    output = password
if stream == 'none':
    output = b'ordinary output'
elif stream == 'near':
    output = b'-synthetic-any-password'
target = sys.stderr.buffer if stream == 'stderr' else sys.stdout.buffer
target.write(b'prefix\0' + output + b'\0suffix\n')
PY
  chmod +x "$HELPER"
  for password in "$PASSWORD" "wrong-synthetic-password" '-[synthetic].*password' ''; do
    for identity in default email login empty-login; do
      identity_env=()
      case "$identity" in
        email) identity_env=(MAILBEND_EMAIL=old@example.com MAILBEND_EMAIL=active@example.com) ;;
        login) identity_env=(MAILBEND_EMAIL=other@example.com MAILBEND_LOGIN=old-login MAILBEND_LOGIN=active-login) ;;
        empty-login) identity_env=(MAILBEND_EMAIL=active@example.com MAILBEND_LOGIN=old-login MAILBEND_LOGIN=) ;;
      esac
      for form in raw login plain; do
        for stream in stdout stderr none near superseded; do
          GLOBAL_LEAK=0
          expected=0
          if [ -n "$password" ]; then
            case "$stream" in stdout|stderr) expected=1 ;; esac
          fi
          call_helper smtp '' MAILBEND_APP_PASSWORD="overridden-synthetic-password" \
              MAILBEND_APP_PASSWORD="$password" "${identity_env[@]}" \
              SYNTHETIC_LEAK_FORM="$form" SYNTHETIC_LEAK_STREAM="$stream"
          status=$?
          if [ "$CODE" -ne 0 ] || [ "$status" -ne "$expected" ] || [ "$GLOBAL_LEAK" -ne "$expected" ]; then
            ok=0
          fi
        done
      done
    done
  done
  if [ "$ok" -eq 1 ]; then
    pass "password leak checker detects active literal/LOGIN/PLAIN bytes on stdout/stderr"
  else
    fail "password leak checker" "synthetic detection or clean-output control failed"
  fi
}

# =========================================================================
# Case 1: IMAP happy path
# =========================================================================
case1() {
  start_server case1 || { fail 1 "server did not start"; return; }
  call_imap $'a1 CAPABILITY\r\na2 LIST "" "*"\r\n'
  CASE1_LOG="$LOG_FILE"
  if [ "$CODE" -eq 0 ] && grep -aq "CAPABILITY" "$OUT" && grep -aq "LIST" "$OUT" && grep -aq "a2 OK" "$OUT"; then
    pass "1 IMAP happy path"
  else
    fail "1 IMAP happy path" "exit=$CODE out=$(cat "$OUT" | tr -d '\r' | tr '\n' '|')"
  fi
  stop_server
}

# =========================================================================
# Case 3: wrong password -> exit 4
# =========================================================================
case3() {
  start_server case3 || { fail 3 "server did not start"; return; }
  call_imap $'a1 NOOP\r\n' MAILBEND_APP_PASSWORD="wrong-password"
  if [ "$CODE" -eq 4 ]; then pass "3 wrong password"; else fail "3 wrong password" "exit=$CODE"; fi
  stop_server
}

# =========================================================================
# Case 4: no MAILBEND_CA_FILE (system trust) -> exit 3
# =========================================================================
case4() {
  start_server case4 || { fail 4 "server did not start"; return; }
  call_imap $'a1 NOOP\r\n' MAILBEND_CA_FILE=""
  if [ "$CODE" -eq 3 ]; then pass "4 no CA file uses system trust and fails"; else fail "4 no CA file uses system trust and fails" "exit=$CODE"; fi
  stop_server
}

# =========================================================================
# Case 5: hostname mismatch -> exit 3 (two sub-cases)
# =========================================================================
case5() {
  local ok=1 detail_a="" detail_b=""
  start_server case5a || { fail 5 "server did not start"; return; }
  call_imap $'a1 NOOP\r\n' MAILBEND_IMAP_HOST="127.0.0.1"
  [ "$CODE" -eq 3 ] || { ok=0; detail_a="127.0.0.1 with localhost cert: exit=$CODE"; }
  stop_server

  start_server case5b --cert-name wronghost || { fail 5 "server did not start"; return; }
  call_imap $'a1 NOOP\r\n'
  [ "$CODE" -eq 3 ] || { ok=0; detail_b="wronghost cert with host localhost: exit=$CODE"; }
  stop_server

  if [ "$ok" -eq 1 ]; then
    pass "5 hostname verification (IP literal and wrong SAN)"
  else
    fail "5 hostname verification (IP literal and wrong SAN)" "${detail_a:-} ${detail_b:-}"
  fi
}

# =========================================================================
# Case 6: expired and self-signed certs -> exit 3
# =========================================================================
case6() {
  local ok=1 detail_a="" detail_b=""
  start_server case6a --cert-name expired || { fail 6 "server did not start"; return; }
  call_imap $'a1 NOOP\r\n'
  [ "$CODE" -eq 3 ] || { ok=0; detail_a="expired cert: exit=$CODE"; }
  stop_server

  start_server case6b --cert-name selfsigned || { fail 6 "server did not start"; return; }
  call_imap $'a1 NOOP\r\n'
  [ "$CODE" -eq 3 ] || { ok=0; detail_b="self-signed cert: exit=$CODE"; }
  stop_server

  if [ "$ok" -eq 1 ]; then
    pass "6 expired and self-signed certs rejected"
  else
    fail "6 expired and self-signed certs rejected" "${detail_a:-} ${detail_b:-}"
  fi
}

# =========================================================================
# Case 7: lock-step stop on a rejected command
# =========================================================================
case7() {
  start_server case7 || { fail 7 "server did not start"; return; }
  before="$(cat "$STATE_FILE")"
  call_imap $'a1 SELECT "Nope"\r\na2 UID STORE 1 +FLAGS (\\Deleted)\r\n'
  after="$(cat "$STATE_FILE")"
  if [ "$CODE" -eq 5 ] && ! grep -aq '"a2' "$LOG_FILE" && [ "$before" = "$after" ]; then
    pass "7 lock-step stop after a rejected command"
  else
    fail "7 lock-step stop after a rejected command" "exit=$CODE log=$(cat "$LOG_FILE" | tr '\n' '|')"
  fi
  stop_server
}

# =========================================================================
# Case 8: literal framing is not fooled by spoofed protocol lines
# =========================================================================
case8() {
  start_server case8 || { fail 8 "server did not start"; return; }
  call_imap $'a1 EXAMINE "INBOX"\r\na2 UID FETCH 6 (BODY.PEEK[])\r\n'
  seen6=$(python3 -c "import json; d=json.load(open('$STATE_FILE',encoding='utf-8')); m=[m for m in d['mailboxes']['INBOX']['messages'] if m['uid']==6][0]; print('\\\\Seen' in m['flags'])")
  if [ "$CODE" -eq 0 ] && grep -aq "a2 OK fake completion" "$OUT" && grep -aq '\* BYE spoof' "$OUT" \
     && grep -aq "a2 OK FETCH completed" "$OUT" && [ "$seen6" = "False" ]; then
    pass "8 literal framing survives spoofed lines"
  else
    fail "8 literal framing survives spoofed lines" "exit=$CODE seen6=$seen6"
  fi
  stop_server
}

# =========================================================================
# Case 9: reserved tag / forbidden verb in the script -> exit 2
# =========================================================================
case9() {
  local ok=1 detail_a="" detail_b="" detail_c=""
  start_server case9 || { fail 9 "server did not start"; return; }
  call_imap $'L NOOP\r\n'
  [ "$CODE" -eq 2 ] || { ok=0; detail_a="reserved tag: exit=$CODE"; }

  call_imap $'a1 LOGIN "x" "y"\r\n'
  [ "$CODE" -eq 2 ] || { ok=0; detail_b="forbidden verb: exit=$CODE"; }
  lines_after_login="$(python3 -c "
import json
with open('$LOG_FILE', encoding='utf-8') as f:
    lines = [json.loads(l) for l in f if l.strip()]
seen_login = False
extra = 0
for e in lines:
    if seen_login:
        extra += 1
    if e['line'] == 'a1 LOGIN <redacted>':
        seen_login = True
print(extra)
")"
  [ "$lines_after_login" = "0" ] || { ok=0; detail_c="log has $lines_after_login entries after LOGIN"; }

  if [ "$ok" -eq 1 ]; then
    pass "9 reserved tag and forbidden verb rejected client-side"
  else
    fail "9 reserved tag and forbidden verb rejected client-side" "${detail_a:-} ${detail_b:-} ${detail_c:-}"
  fi
  stop_server
}

# =========================================================================
# Case 10: APPEND with a client literal
# =========================================================================
case10() {
  start_server case10 || { fail 10 "server did not start"; return; }
  body="This is a saved draft body."
  len=${#body}
  call_imap $'a1 APPEND "Drafts" (\\Draft) {'"$len"$'}\r\n'"$body"$'\r\n'
  draft_ok=$(python3 -c "
import json
d = json.load(open('$STATE_FILE', encoding='utf-8'))
drafts = d['mailboxes']['Drafts']['messages']
ok = len(drafts) == 1 and '\\\\Draft' in drafts[0]['flags'] and drafts[0]['raw'] == '''$body'''
print(ok)
")
  if [ "$CODE" -eq 0 ] && [ "$draft_ok" = "True" ]; then
    pass "10 APPEND with a client literal"
  else
    fail "10 APPEND with a client literal" "exit=$CODE draft_ok=$draft_ok"
  fi
  stop_server
}

# =========================================================================
# Case 11: 8-bit byte transparency
# =========================================================================
case11() {
  start_server case11 || { fail 11 "server did not start"; return; }
  call_imap $'a1 EXAMINE "INBOX"\r\na2 UID FETCH 5 (BODY.PEEK[])\r\n'
  if [ "$CODE" -eq 0 ] && grep -aq $'\xc3\xa9' "$OUT"; then
    pass "11 8-bit byte 0xE9 comes out as UTF-8 c3 a9"
  else
    fail "11 8-bit byte 0xE9 comes out as UTF-8 c3 a9" "exit=$CODE"
  fi
  stop_server
}

# =========================================================================
# Case 12: SMTP happy path
# =========================================================================
case12() {
  start_server case12 || { fail 12 "server did not start"; return; }
  body=$'Subject: hello\r\n\r\nHi there.\r\n'
  call_smtp $'MAIL FROM:<'"$FIXTURE_USER"$'>\r\nRCPT TO:<friend@example.com>\r\nRCPT TO:<second@example.com>\r\nDATA\r\n'"$body"$'.\r\n'
  CASE12_LOG="$LOG_FILE"
  ok=$(python3 -c "
import json
d = json.load(open('$STATE_FILE', encoding='utf-8'))
sent = d.get('sent', [])
ok = (len(sent) == 1 and sent[0]['mail_from'] == '$FIXTURE_USER'
      and set(sent[0]['rcpt_to']) == {'friend@example.com', 'second@example.com'})
print(ok)
")
  starttls_first=$(python3 -c "
import json
lines = [json.loads(l)['line'] for l in open('$LOG_FILE', encoding='utf-8') if l.strip()]
st = next((i for i, l in enumerate(lines) if l == 'STARTTLS'), None)
au = next((i for i, l in enumerate(lines) if l == 'AUTH <redacted>'), None)
print(st is not None and au is not None and st < au)
")
  if [ "$CODE" -eq 0 ] && [ "$ok" = "True" ] && [ "$starttls_first" = "True" ]; then
    pass "12 SMTP happy path"
  else
    fail "12 SMTP happy path" "exit=$CODE ok=$ok starttls_first=$starttls_first"
  fi
  stop_server
}

# =========================================================================
# Case 13: SMTP rejected recipient
# =========================================================================
case13() {
  start_server case13 || { fail 13 "server did not start"; return; }
  body=$'Subject: x\r\n\r\nbody\r\n'
  call_smtp $'MAIL FROM:<'"$FIXTURE_USER"$'>\r\nRCPT TO:<reject@example.com>\r\nDATA\r\n'"$body"$'.\r\n'
  no_data=$(python3 -c "
import json
lines = [json.loads(l)['line'] for l in open('$LOG_FILE', encoding='utf-8') if l.strip()]
print(not any(l == 'DATA' for l in lines))
")
  if [ "$CODE" -eq 5 ] && [ "$no_data" = "True" ]; then
    pass "13 SMTP rejected recipient stops before DATA"
  else
    fail "13 SMTP rejected recipient stops before DATA" "exit=$CODE no_data=$no_data"
  fi
  stop_server
}

# =========================================================================
# Case 14: SMTP server without STARTTLS
# =========================================================================
case14() {
  start_server case14 --no-starttls || { fail 14 "server did not start"; return; }
  call_smtp ''
  no_auth=$(python3 -c "
import json
lines = [json.loads(l)['line'] for l in open('$LOG_FILE', encoding='utf-8') if l.strip()]
print(not any('AUTH' in l for l in lines))
")
  if [ "$CODE" -eq 3 ] && [ "$no_auth" = "True" ]; then
    pass "14 SMTP server without STARTTLS is refused"
  else
    fail "14 SMTP server without STARTTLS is refused" "exit=$CODE no_auth=$no_auth"
  fi
  stop_server
}

# =========================================================================
# Case 15: envelope may not greet/authenticate/quit -> exit 2
# =========================================================================
case15() {
  local ok=1 detail_a="" detail_b="" detail_c=""
  start_server case15 || { fail 15 "server did not start"; return; }

  call_smtp $'AUTH PLAIN AAA=\r\n'
  [ "$CODE" -eq 2 ] || { ok=0; detail_a="AUTH: exit=$CODE"; }

  call_smtp $'QUIT\r\n'
  [ "$CODE" -eq 2 ] || { ok=0; detail_b="QUIT: exit=$CODE"; }

  call_smtp $'EHLO evil\r\n'
  [ "$CODE" -eq 2 ] || { ok=0; detail_c="EHLO: exit=$CODE"; }

  if [ "$ok" -eq 1 ]; then
    pass "15 envelope may not AUTH/QUIT/EHLO"
  else
    fail "15 envelope may not AUTH/QUIT/EHLO" "${detail_a:-} ${detail_b:-} ${detail_c:-}"
  fi
  stop_server
}

# =========================================================================
# Case 16: timeout against a silent listener
# =========================================================================
case16() {
  start_server case16 --silent-port || { fail 16 "server did not start"; return; }
  if [ -z "$SILENT_PORT" ]; then fail "16 timeout against a silent listener" "no silent port"; stop_server; return; fi
  start_ts=$(date +%s)
  TIMEOUT_MS=1500 HELPER_TIMEOUT_S=6 call_imap '' MAILBEND_IMAP_PORT="$SILENT_PORT"
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  if { [ "$CODE" -eq 3 ] || [ "$CODE" -eq 6 ]; } && [ "$elapsed" -le 5 ]; then
    pass "16 timeout against a silent listener"
  else
    fail "16 timeout against a silent listener" "exit=$CODE elapsed=${elapsed}s"
  fi
  stop_server
}

# =========================================================================
# Case 17: server-refused literal (APPEND to a nonexistent mailbox)
# =========================================================================
case17() {
  start_server case17 || { fail 17 "server did not start"; return; }
  body="hello mail"
  len=${#body}
  start_ts=$(date +%s)
  call_imap $'a1 APPEND "NoSuchBox" (\\Draft) {'"$len"$'}\r\n'"$body"$'\r\n'
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  if [ "$CODE" -eq 5 ] && [ "$elapsed" -le 5 ]; then
    pass "17 server-refused literal (no hang)"
  else
    fail "17 server-refused literal (no hang)" "exit=$CODE elapsed=${elapsed}s"
  fi
  stop_server
}

# =========================================================================
# Case 18: a server that echoes the credentials in its login replies cannot
# pass them on: authentication replies never reach the transcript.
# =========================================================================
case18() {
  start_server case18 --echo-login || { fail 18 "server did not start"; return; }
  ok=1; detail=""
  call_imap $'a1 NOOP\r\n'
  if [ "$CODE" -ne 0 ] || grep -aq "LOGIN completed" "$OUT"; then
    ok=0; detail="imap exit=$CODE"
  fi
  body=$'Subject: echo\r\n\r\nhi\r\n'
  call_smtp $'MAIL FROM:<'"$FIXTURE_USER"$'>\r\nRCPT TO:<friend@example.com>\r\nDATA\r\n'"$body"$'.\r\n'
  if [ "$CODE" -ne 0 ] || grep -aq "^235" "$OUT"; then
    ok=0; detail="$detail smtp exit=$CODE"
  fi
  if [ "$ok" -eq 1 ]; then
    pass "18 echoed credentials never reach the transcript"
  else
    fail "18 echoed credentials never reach the transcript" "$detail"
  fi
  stop_server
}

# =========================================================================
# Case 19: =EXPECT compares response keywords in any case (IMAP keywords are
# case-insensitive) but still needs the exact value.
# =========================================================================
case19() {
  start_server case19 --lowercase-codes || { fail 19 "server did not start"; return; }
  ok=1; detail=""
  call_imap $'a1 SELECT INBOX\r\n=EXPECT * OK [UIDVALIDITY 1700000001]\r\na2 NOOP\r\n'
  if [ "$CODE" -ne 0 ] || ! grep -aq "a2 OK" "$OUT"; then ok=0; detail="match: exit=$CODE"; fi
  call_imap $'a1 SELECT INBOX\r\n=EXPECT * OK [UIDVALIDITY 1700000009]\r\na2 NOOP\r\n'
  if [ "$CODE" -ne 5 ] || grep -aq "a2 OK" "$OUT"; then ok=0; detail="$detail mismatch: exit=$CODE"; fi
  if [ "$ok" -eq 1 ]; then
    pass "19 =EXPECT ignores keyword case, not the value"
  else
    fail "19 =EXPECT ignores keyword case, not the value" "$detail"
  fi
  stop_server
}

# =========================================================================
# Case 20: a closing SMTP rejection (421, then the server hangs up) is
# reported as a rejection, not replaced by a transport error from QUIT.
# =========================================================================
case20() {
  start_server case20 || { fail 20 "server did not start"; return; }
  body=$'Subject: x\r\n\r\nhi\r\n'
  call_smtp $'MAIL FROM:<'"$FIXTURE_USER"$'>\r\nRCPT TO:<closing@example.com>\r\nDATA\r\n'"$body"$'.\r\n'
  if [ "$CODE" -eq 5 ] && grep -aq "^421" "$OUT"; then
    pass "20 a closing 421 stays a rejection"
  else
    fail "20 a closing 421 stays a rejection" "exit=$CODE $(tr -d '\r' <"$ERR")"
  fi
  stop_server
}

# =========================================================================
# Case 21: a final LOGOUT or QUIT reply cut off mid-line, after every
# command was accepted, keeps the run a success (a retry would duplicate
# the draft or the mail).
# =========================================================================
case21() {
  start_server case21 --cut-goodbye || { fail 21 "server did not start"; return; }
  ok=1; detail=""
  body="cut-off logout draft"
  call_imap $'a1 APPEND "Drafts" (\\Draft) {'"${#body}"$'}\r\n'"$body"$'\r\n'
  if [ "$CODE" -ne 0 ] || [ -s "$ERR" ] || ! grep -aq "a1 OK" "$OUT"; then
    ok=0; detail="imap exit=$CODE $(tr -d '\r' <"$ERR")"
  fi
  body=$'Subject: x\r\n\r\nhi\r\n'
  call_smtp $'MAIL FROM:<'"$FIXTURE_USER"$'>\r\nRCPT TO:<friend@example.com>\r\nDATA\r\n'"$body"$'.\r\n'
  if [ "$CODE" -ne 0 ] || ! grep -qx "mailbend-smtp: data_accepted" "$ERR"; then
    ok=0; detail="$detail smtp exit=$CODE $(tr -d '\r' <"$ERR")"
  fi
  if [ "$ok" -eq 1 ]; then
    pass "21 a cut-off LOGOUT or QUIT reply keeps the success"
  else
    fail "21 a cut-off LOGOUT or QUIT reply keeps the success" "$detail"
  fi
  stop_server
}

# Fixed SMTP evidence distinguishes refusal from loss of the final reply.
case_smtp_progress() {
  start_server smtp-progress --echo-login || { fail smtp-progress "server did not start"; return; }
  body=$'Subject: outcome\r\n\r\nsynthetic\r\n'
  for entry in before-data-close:6:before_data final-reject:5:data_rejected lost-reply:6:data_started bare-reply:0:data_accepted; do
    IFS=: read -r rcpt expected phase <<< "$entry"
    call_smtp $'MAIL FROM:<'"$FIXTURE_USER"$'>\r\nRCPT TO:<'"$rcpt"$'@example.com>\r\nDATA\r\n'"$body"$'.\r\n'
    last=$(grep '^mailbend-smtp: ' "$ERR" | tail -1)
    if [ "$CODE" -eq "$expected" ] && [ "$last" = "mailbend-smtp: $phase" ]; then
      pass "SMTP $rcpt progress"
    else
      fail "SMTP $rcpt progress" "exit=$CODE last=$last"
    fi
  done
  stop_server
}

# =========================================================================
# Case 2: the fixture password never leaks, and LOGIN/AUTH are redacted in
# the log. Aggregates over every call made by every other case above, so it
# runs last.
# =========================================================================
case2() {
  login_redacted="False"
  if [ -n "$CASE1_LOG" ] && grep -aq '"line": "L LOGIN <redacted>"' "$CASE1_LOG"; then
    login_redacted="True"
  fi
  auth_redacted="False"
  if [ -n "$CASE12_LOG" ] && grep -aq '"line": "AUTH <redacted>"' "$CASE12_LOG"; then
    auth_redacted="True"
  fi
  if [ "$GLOBAL_LEAK" -eq 0 ] && [ "$login_redacted" = "True" ] && [ "$auth_redacted" = "True" ]; then
    pass "2 password never leaks; LOGIN/AUTH redacted in the log"
  else
    fail "2 password never leaks; LOGIN/AUTH redacted in the log" \
      "leak=$GLOBAL_LEAK login_redacted=$login_redacted auth_redacted=$auth_redacted"
  fi
}

# Numeric section partials retain literal framing and the UIDVALIDITY guard.
case_selected_section() {
  start_server case_selected_section || { fail selected-section "server did not start"; return; }
  call_imap $'a1 EXAMINE INBOX\r\n=EXPECT * OK [UIDVALIDITY 1700000001]\r\na2 UID FETCH 4 (UID BODYSTRUCTURE BODY.PEEK[2]<0.64>)\r\n'
  if [ "$CODE" -eq 0 ] && grep -aq 'BODY\[2\]<0>' "$OUT" && grep -aq 'JVBERi0xLjQKJeLjz9MK' "$OUT"; then
    pass "selected PEEK literal"
  else
    fail "selected PEEK literal" "exit=$CODE"
  fi
  call_imap $'a1 EXAMINE INBOX\r\n=EXPECT * OK [UIDVALIDITY 9]\r\na2 UID FETCH 4 (UID BODY.PEEK[2]<0.64>)\r\n'
  if [ "$CODE" -ne 0 ] && ! grep -aq 'BODY\[2\]' "$OUT"; then
    pass "selected section stale generation stops before selected read"
  else
    fail "selected section stale generation stops before selected read" "exit=$CODE"
  fi
  stop_server
}

# The bounded refresh plan guards read identities before fetching flags.
case_refresh() {
  start_server case_refresh || { fail 22 "server did not start"; return; }
  call_imap $'a1 EXAMINE "INBOX"\r\n=EXPECT * OK [UIDVALIDITY 1700000001]\r\na2 UID FETCH 1,99 (UID FLAGS)\r\na3 UID SEARCH UID 1,99\r\n'
  if [ "$CODE" -eq 0 ] && grep -aq 'a3 OK' "$OUT" && grep -aq '\* SEARCH 1' "$OUT"; then
    pass "22 refresh reads flags and presence in one guarded session"
  else
    fail "22 refresh reads flags and presence" "exit=$CODE"
  fi
  stop_server
  start_server case-refresh-stale || { fail 22 "server did not start"; return; }
  call_imap $'a1 EXAMINE "INBOX"\r\n=EXPECT * OK [UIDVALIDITY 7]\r\na2 UID FETCH 1 (UID FLAGS)\r\na3 UID SEARCH UID 1\r\n'
  if [ "$CODE" -eq 5 ] && ! grep -aq 'UID FETCH\|UID SEARCH' "$LOG_FILE"; then
    pass "22 stale refresh stops before any UID operation"
  else
    fail "22 stale refresh guard" "exit=$CODE"
  fi
  stop_server
}

# Both modes share the envelope and credential-redaction path.
case_smtp_modes() {
  local mode cert extra start elapsed
  for mode in starttls implicit; do
    extra=""
    [ "$mode" = implicit ] && extra="--smtp-implicit"
    start_server "smtp-$mode" $extra --echo-login || { fail "$mode" "server did not start"; return; }
    call_smtp $'MAIL FROM:<user@example.com>\r\nRCPT TO:<friend@example.com>\r\nDATA\r\nSubject: mode\r\n\r\nhello\r\n.\r\n' MAILBEND_SMTP_TLS_MODE="$mode"
    if [ "$CODE" -eq 0 ] && python3 - "$LOG_FILE" "$mode" <<'PY'
import json, sys
lines = [json.loads(line)['line'] for line in open(sys.argv[1])]
ehlo = [i for i, l in enumerate(lines) if l.startswith('EHLO ')]
auth = next(i for i, l in enumerate(lines) if l == 'AUTH <redacted>')
assert len(ehlo) == (2 if sys.argv[2] == 'starttls' else 1)
assert ehlo[-1] < auth
assert ('STARTTLS' in lines) == (sys.argv[2] == 'starttls')
PY
    then pass "$mode SMTP negotiation and send"; else fail "$mode SMTP negotiation and send" "exit=$CODE"; fi
    stop_server
    start_server "smtp-reject-$mode" $extra || { fail "$mode RCPT rejection" "server did not start"; return; }
    call_smtp $'MAIL FROM:<user@example.com>\r\nRCPT TO:<reject@example.com>\r\nDATA\r\nSubject: mode\r\n\r\nhello\r\n.\r\n' MAILBEND_SMTP_TLS_MODE="$mode"
    if [ "$CODE" -eq 5 ] && ! grep -aq '"line": "DATA"' "$LOG_FILE"; then pass "$mode RCPT rejection prevents DATA"; else fail "$mode RCPT rejection" "exit=$CODE"; fi
    stop_server
    for cert in wronghost expired selfsigned; do
      start_server "smtp-$mode-$cert" $extra --cert-name "$cert" || { fail "$mode rejects $cert" "server did not start"; return; }
      call_smtp '' MAILBEND_SMTP_TLS_MODE="$mode"
      if [ "$CODE" -eq 3 ] && ! grep -aq 'AUTH' "$LOG_FILE"; then pass "$mode rejects $cert before AUTH"; else fail "$mode rejects $cert" "exit=$CODE"; fi
      stop_server
    done
    start_server "smtp-silent-$mode" --silent-port || { fail "$mode silent endpoint" "server did not start"; return; }
    start=$SECONDS
    call_smtp '' MAILBEND_SMTP_TLS_MODE="$mode" MAILBEND_SMTP_PORT="$SILENT_PORT" MAILBEND_TIMEOUT_MS=300
    elapsed=$((SECONDS - start))
    if [ "$CODE" -ne 0 ] && [ "$elapsed" -lt 5 ] && [ ! -s "$OUT" ]; then pass "$mode silent endpoint bounded"; else fail "$mode silent endpoint" "exit=$CODE elapsed=$elapsed"; fi
    stop_server
  done
  for mode in starttls implicit; do
    extra="--smtp-implicit"
    [ "$mode" = implicit ] && extra=""
    start_server "smtp-wrong-$mode" $extra || { fail "$mode wrong endpoint" "server did not start"; return; }
    start=$SECONDS
    call_smtp '' MAILBEND_SMTP_TLS_MODE="$mode" MAILBEND_TIMEOUT_MS=300
    elapsed=$((SECONDS - start))
    if [ "$CODE" -ne 0 ] && [ "$elapsed" -lt 5 ] && ! grep -aq 'AUTH' "$LOG_FILE"; then pass "$mode wrong endpoint fails without AUTH"; else fail "$mode wrong endpoint" "exit=$CODE elapsed=$elapsed"; fi
    stop_server
  done
}

# Authentication replies are private. Only exact fixed evidence escapes the helper.
case_auth_refusals() {
  local name protocol stage reason expected attempts fixture mode extra actual count
  python3 - "$ROOT/tests" "$FIXTURE" "$WORK" <<'PYCASES'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1])
from auth_refusal_cases import cases
fixture = json.loads(pathlib.Path(sys.argv[2]).read_text())
work = pathlib.Path(sys.argv[3])
with (work / 'auth-cases.tsv').open('w') as listing:
    for name, protocol, stage, reason, expected, attempts, changes in cases(fixture['password']):
        path = work / (name + '.json')
        path.write_text(json.dumps({**fixture, **changes}))
        print(name, protocol, stage, reason, expected, attempts, path, sep='\t', file=listing)
PYCASES
  while IFS=$'\t' read -r name protocol stage reason expected attempts fixture; do
    for mode in starttls implicit; do
      # IMAP has only implicit verified TLS.
      [ "$protocol" = imap ] && [ "$mode" = starttls ] && continue
      extra=()
      [ "$mode" = implicit ] && extra=(--smtp-implicit)
      start_server "$name-$mode" --fixture "$fixture" "${extra[@]}" || {
        fail "$name-$mode" "server did not start"; continue;
      }
      if [ "$protocol" = imap ]; then
        call_imap $'a1 NOOP\r\n'
      else
        call_smtp $'MAIL FROM:<user@example.com>\r\nRCPT TO:<friend@example.com>\r\nDATA\r\nSubject: forbidden\r\n\r\nbody\r\n.\r\n' MAILBEND_SMTP_TLS_MODE="$mode"
      fi
      actual=$(grep '^mailbend-auth: ' "$ERR")
      count=$(python3 - "$LOG_FILE" "$protocol" "$stage" <<'PYCOUNT'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
protocol, stage = sys.argv[2:]
lines = [r['line'] for r in records if r['proto'] == protocol]
if stage == 'greeting':
    assert sum(r['proto'] == protocol + '-refusal' for r in records) == 1
    assert not lines
else:
    assert not any('NOOP' in line or line.startswith(('MAIL ', 'RCPT ', 'DATA')) for line in lines)
print(sum(' LOGIN ' in line or line == 'AUTH <redacted>' for line in lines))
PYCOUNT
      )
      if [ "$CODE" -eq "$expected" ] && [ "$actual" = "mailbend-auth: $reason" ] && \
         [ "$count" = "$attempts" ] && ! grep -aq 'private-server-marker' "$OUT" "$ERR" && \
         ! grep -aq -- "$PASSWORD" "$OUT" "$ERR"; then
        pass "$name-$mode fixed evidence, no retry or credential leak"
      else
        fail "$name-$mode fixed evidence" "exit=$CODE reason=$actual auth_lines=$count"
      fi
      call_helper "diagnose-$protocol" '' MAILBEND_IMAP_HOST=localhost \
          MAILBEND_IMAP_PORT="$IMAP_PORT" MAILBEND_SMTP_HOST=localhost \
          MAILBEND_SMTP_PORT="$SMTP_PORT" MAILBEND_SMTP_TLS_MODE="$mode"
      if [ "$CODE" -eq 0 ] && grep -axq "$stage $reason" "$OUT" && [ ! -s "$ERR" ] && \
         ! grep -aq 'private-server-marker' "$OUT" && ! grep -aq -- "$PASSWORD" "$OUT" && \
         python3 - "$LOG_FILE" "$protocol" "$stage" "$attempts" <<'PYDIAG'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
protocol, stage, attempts = sys.argv[2:]
lines = [r['line'] for r in records if r['proto'] == protocol]
assert sum(' LOGIN ' in line or line == 'AUTH <redacted>' for line in lines) == int(attempts) * 2
assert not any('NOOP' in line or line.startswith(('MAIL ', 'RCPT ', 'DATA')) for line in lines)
if stage == 'greeting':
    assert sum(r['proto'] == protocol + '-refusal' for r in records) == 2
    assert not lines
PYDIAG
      then
        pass "$name-$mode native diagnosis is redacted and does not retry"
      else
        fail "$name-$mode native diagnosis" "exit=$CODE"
      fi
      stop_server
    done
  done < "$WORK/auth-cases.tsv"
}

# Exercise authenticate through the actual helper, not only has_auth. The
# fake server redacts every AUTH command and LOGIN challenge response: one
# redacted line is PLAIN, three are LOGIN. Check the complete wire sequence
# so retries, premature AUTH and mail commands cannot hide behind success.
case_smtp_auth_selection() {
  local base_fixture="$FIXTURE" FIXTURE="$WORK/smtp-auth-fixture.json"
  local mode extra name offer mechanism expected password
  for mode in starttls implicit; do
    extra=""
    [ "$mode" = implicit ] && extra="--smtp-implicit"
    while IFS='|' read -r name offer mechanism expected; do
      python3 - "$base_fixture" "$FIXTURE" "$offer" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as source:
    fixture = json.load(source)
fixture['smtp_auth'] = sys.argv[3]
# In STARTTLS mode, a conflicting unprotected offer must be ignored.
# Implicit TLS has no unprotected EHLO and never uses this fixture field.
fixture['smtp_auth_before_tls'] = 'PLAIN OAUTHBEARER'
with open(sys.argv[2], 'w', encoding='utf-8') as target:
    json.dump(fixture, target)
PY
      if [ "$?" -ne 0 ]; then fail "SMTP AUTH fixture" "could not write fixture"; return; fi
      start_server "smtp-auth-$mode-$name" $extra || {
        fail "$mode AUTH $name" "server did not start"; return;
      }
      password="$PASSWORD"
      [ "$name" = rejected-plain ] && password="wrong-synthetic-password"
      if ! call_smtp '' MAILBEND_SMTP_TLS_MODE="$mode" MAILBEND_APP_PASSWORD="$password"; then
        fail "$mode AUTH $name" "password leaked to stdout/stderr"
      elif [ "$CODE" -ne "$expected" ]; then
        fail "$mode AUTH $name expects $mechanism" "exit=$CODE expected=$expected"
      elif python3 - "$LOG_FILE" "$STATE_FILE" "$mode" "$mechanism" "$expected" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as source:
    lines = [json.loads(line)['line'] for line in source]
mode, mechanism, code = sys.argv[3], sys.argv[4], int(sys.argv[5])
hello = 'EHLO [127.0.0.1]'
expected = [hello, 'STARTTLS', hello] if mode == 'starttls' else [hello]
auth_lines = {'PLAIN': 1, 'LOGIN': 3, 'none': 0}[mechanism]
expected += ['AUTH <redacted>'] * auth_lines
if code == 0:
    expected.append('QUIT')
# Only fixed, redacted command labels may appear in diagnostics. A broken
# fake-server redactor must fail without copying credential bytes to CI.
safe_lines = [line if line in {hello, 'STARTTLS', 'AUTH <redacted>', 'QUIT'}
              else '<unexpected line redacted>' for line in lines]
assert lines == expected, f'expected {expected!r}, got {safe_lines!r}'
with open(sys.argv[2], encoding='utf-8') as source:
    assert not json.load(source).get('sent'), 'authentication test sent mail'
PY
      then
        pass "$mode AUTH $name selects $mechanism without retry"
      else
        fail "$mode AUTH $name expects $mechanism" "wire sequence or sent-state mismatch (exit=$CODE matched expected)"
      fi
      stop_server
    done <<'CASES'
malformed-plain|PLAIN] LOGIN|LOGIN|0
plain-first|PLAIN LOGIN|PLAIN|0
plain-last|LOGIN PLAIN|PLAIN|0
malformed-only|PLAIN] LOGIN]|none|4
rejected-plain|PLAIN LOGIN|PLAIN|4
CASES
  done
}

# --- run every case -------------------------------------------------------
case_password_leak_check
case1
case3
case4
case5
case6
case7
case8
case9
case10
case11
case12
case13
case14
case15
case16
case17
case18
case19
case20
case21
case_smtp_progress
case_selected_section
case_refresh
case_smtp_modes
case_auth_refusals
case_smtp_auth_selection
case2
if python3 "$ROOT/tests/test-process-protection.py"; then
  pass "secret helpers refuse dumps and external environment reads"
else
  fail "secret helper process protection" "process checks failed"
fi

echo "transport: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
