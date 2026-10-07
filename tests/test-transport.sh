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
if ! { (cd "$ROOT/native" && "${CARGO:-cargo}" build --release --locked --quiet -p mailbend-tls) \
       && cp "$ROOT/native/target/release/mailbend-tls" "$HELPER"; } 2>"$WORK/build.err"; then
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
  local protocol="$1" script="$2"
  shift 2
  printf '%s' "$script" >"$WORK/in.txt"
  OUT="$WORK/out.bin"; ERR="$WORK/err.txt"
  env MAILBEND_EMAIL="$FIXTURE_USER" MAILBEND_APP_PASSWORD="$PASSWORD" \
      MAILBEND_CA_FILE="$CERTDIR/ca.pem" MAILBEND_TIMEOUT_MS="${TIMEOUT_MS:-5000}" \
      "$@" "$HELPER" "$protocol" <"$WORK/in.txt" >"$OUT" 2>"$ERR"
  CODE=$?
  check_leak
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
  if grep -aq -- "$PASSWORD" "$OUT" "$ERR" 2>/dev/null; then
    GLOBAL_LEAK=1
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
  save_imap_port="$IMAP_PORT"
  IMAP_PORT="$SILENT_PORT"
  start_ts=$(date +%s)
  TIMEOUT_MS=1500 timeout 6 env MAILBEND_EMAIL="$FIXTURE_USER" MAILBEND_APP_PASSWORD="$PASSWORD" \
      MAILBEND_CA_FILE="$CERTDIR/ca.pem" MAILBEND_IMAP_HOST=localhost \
      MAILBEND_IMAP_PORT="$IMAP_PORT" MAILBEND_TIMEOUT_MS=1500 \
      "$HELPER" imap </dev/null >"$WORK/out.bin" 2>"$WORK/err.txt"
  CODE=$?
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  IMAP_PORT="$save_imap_port"
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
  if [ "$CODE" -ne 0 ] || grep -aq -- "$PASSWORD" "$OUT" || grep -aq "LOGIN completed" "$OUT"; then
    ok=0; detail="imap exit=$CODE"
  fi
  body=$'Subject: echo\r\n\r\nhi\r\n'
  call_smtp $'MAIL FROM:<'"$FIXTURE_USER"$'>\r\nRCPT TO:<friend@example.com>\r\nDATA\r\n'"$body"$'.\r\n'
  if [ "$CODE" -ne 0 ] || grep -aq -- "$PASSWORD" "$OUT" || grep -aq "^235" "$OUT"; then
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
  if [ "$CODE" -ne 0 ] || [ -s "$ERR" ]; then
    ok=0; detail="$detail smtp exit=$CODE $(tr -d '\r' <"$ERR")"
  fi
  if [ "$ok" -eq 1 ]; then
    pass "21 a cut-off LOGOUT or QUIT reply keeps the success"
  else
    fail "21 a cut-off LOGOUT or QUIT reply keeps the success" "$detail"
  fi
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

# --- run every case -------------------------------------------------------
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
case2

echo "transport: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
