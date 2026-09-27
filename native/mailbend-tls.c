/*
 * mailbend-tls: the verified TLS transport behind MailBend.
 *
 *   mailbend-tls imap   < commands    > server transcript
 *   mailbend-tls smtp   < envelope    > server transcript
 *
 * This file is the whole native boundary. It owns only sockets, TLS and
 * authentication; which commands to send, and what the answers mean, is
 * decided by the Bend core. Rules kept here:
 *
 *  - the certificate chain and the host name are always verified; there is
 *    no switch to turn verification off (MAILBEND_CA_FILE only replaces the
 *    trust store, e.g. for the local test server);
 *  - credentials come from MAILBEND_EMAIL / MAILBEND_APP_PASSWORD, are sent
 *    only to the verified server, and are never written to stdout/stderr;
 *  - every read is bounded in size and time;
 *  - commands run one at a time and the run stops at the first rejection, so
 *    a later command never acts on the result of a failed earlier one.
 *
 * IMAP stdin: tagged commands in IMAP wire form (CRLF lines; a line ending
 * in {N} is followed by N literal bytes). Tags "L" and "Z" are reserved for
 * the helper's own LOGIN and LOGOUT, and LOGIN/AUTHENTICATE/STARTTLS are
 * refused. The helper waits for each command's tagged answer before sending
 * the next one.
 *
 * SMTP stdin: envelope lines (MAIL FROM, RCPT TO, ...), then DATA and the
 * dot-stuffed message ending in a "." line. EHLO, STARTTLS and AUTH are
 * done by the helper.
 *
 * stdout: the server's bytes, with each byte 0x80-0xFF written as the UTF-8
 * encoding of U+0080-U+00FF, so the Bend side reads exactly one character
 * per server byte and IMAP literal lengths stay exact.
 *
 * Exit status: 0 ok, 2 usage/config, 3 connect/TLS/verification,
 * 4 authentication rejected, 5 command rejected, 6 protocol/timeout/limit.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

enum { EX_OK = 0, EX_USAGE = 2, EX_CONNECT = 3, EX_AUTH = 4, EX_REJECTED = 5, EX_PROTO = 6 };

#define MAX_LINE (32u << 20)         /* one response line (a big SEARCH reply) */
#define MAX_LITERAL (64u << 20)      /* one IMAP literal */
#define MAX_SCRIPT (64u << 20)       /* the whole command script */
#define MAX_OUTPUT (60ull << 20)     /* transcript bytes; at most doubled on stdout */

static int sock = -1;
static SSL *ssl = NULL;
static unsigned long long out_total = 0;

__attribute__((noreturn, format(printf, 2, 3)))
static void die(int code, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fputs("mailbend-tls: ", stderr);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  fflush(stdout);
  exit(code);
}

static const char *env_or(const char *name, const char *fallback) {
  const char *v = getenv(name);
  return (v && *v) ? v : fallback;
}

/* ---- output ------------------------------------------------------------ */

static void emit(const unsigned char *p, size_t n) {
  out_total += n;
  if (out_total > MAX_OUTPUT) die(EX_PROTO, "transcript exceeds the output limit");
  for (size_t i = 0; i < n; i++) {
    unsigned char c = p[i];
    if (c < 0x80) {
      putchar(c);
    } else {
      putchar(0xC0 | (c >> 6));
      putchar(0x80 | (c & 0x3F));
    }
  }
}

/* ---- transport --------------------------------------------------------- */

static unsigned char rbuf[16384];
static size_t rlen = 0, rpos = 0;

static int raw_read(void *p, size_t n) {
  if (ssl) {
    int r = SSL_read(ssl, p, (int)n);
    return r > 0 ? r : -1;
  }
  ssize_t r = recv(sock, p, n, 0);
  return r > 0 ? (int)r : -1;
}

static void raw_write(const void *p, size_t n) {
  const unsigned char *b = p;
  while (n > 0) {
    int w;
    if (ssl) {
      w = SSL_write(ssl, b, n > 65536 ? 65536 : (int)n);
    } else {
      ssize_t s = send(sock, b, n, MSG_NOSIGNAL);
      w = s > 0 ? (int)s : -1;
    }
    if (w <= 0) die(EX_PROTO, "write to server failed or timed out");
    b += w;
    n -= (size_t)w;
  }
}

static int fill(void) {
  if (rpos < rlen) return 1;
  int r = raw_read(rbuf, sizeof rbuf);
  if (r <= 0) return 0;
  rlen = (size_t)r;
  rpos = 0;
  return 1;
}

/* Reads one line including its LF into *line (malloc'd). Returns length, or
 * -1 at end of stream. */
static long read_line(unsigned char **line) {
  size_t cap = 256, n = 0;
  unsigned char *b = malloc(cap);
  if (!b) die(EX_PROTO, "out of memory");
  for (;;) {
    if (!fill()) {
      if (n == 0) { free(b); return -1; }
      die(EX_PROTO, "connection closed mid-line or read timed out");
    }
    unsigned char c = rbuf[rpos++];
    if (n + 1 >= cap) {
      if (cap >= MAX_LINE) die(EX_PROTO, "server line exceeds the line limit");
      cap *= 2;
      b = realloc(b, cap);
      if (!b) die(EX_PROTO, "out of memory");
    }
    b[n++] = c;
    if (c == '\n') break;
  }
  b[n] = 0;
  *line = b;
  return (long)n;
}

/* Copies exactly n server bytes to stdout. */
static void pass_bytes(unsigned long long n) {
  while (n > 0) {
    if (!fill()) die(EX_PROTO, "connection closed inside a literal or read timed out");
    size_t take = rlen - rpos;
    if (take > n) take = (size_t)n;
    emit(rbuf + rpos, take);
    rpos += take;
    n -= take;
  }
}

static void set_timeouts(int fd, int ms) {
  struct timeval tv = { ms / 1000, (ms % 1000) * 1000 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

static void tcp_connect(const char *host, const char *port, int timeout_ms) {
  struct addrinfo hints = {0}, *res = NULL;
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host, port, &hints, &res) != 0 || !res)
    die(EX_CONNECT, "cannot resolve %s", host);
  for (struct addrinfo *a = res; a; a = a->ai_next) {
    int fd = socket(a->ai_family, a->ai_socktype | SOCK_CLOEXEC, a->ai_protocol);
    if (fd < 0) continue;
    int fl = fcntl(fd, F_GETFL);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int r = connect(fd, a->ai_addr, a->ai_addrlen);
    if (r < 0 && errno == EINPROGRESS) {
      struct pollfd p = { fd, POLLOUT, 0 };
      int err = 0;
      socklen_t el = sizeof err;
      if (poll(&p, 1, timeout_ms) == 1 &&
          getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el) == 0 && err == 0)
        r = 0;
    }
    if (r == 0) {
      fcntl(fd, F_SETFL, fl);
      set_timeouts(fd, timeout_ms);
      sock = fd;
      break;
    }
    close(fd);
  }
  freeaddrinfo(res);
  if (sock < 0) die(EX_CONNECT, "cannot connect to %s:%s", host, port);
}

static void tls_start(const char *host) {
  SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
  if (!ctx) die(EX_CONNECT, "cannot create a TLS context");
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
  const char *ca = getenv("MAILBEND_CA_FILE");
  int loaded = (ca && *ca) ? SSL_CTX_load_verify_locations(ctx, ca, NULL)
                           : SSL_CTX_set_default_verify_paths(ctx);
  if (loaded != 1) die(EX_CONNECT, "cannot load the trust store");

  ssl = SSL_new(ctx);
  if (!ssl) die(EX_CONNECT, "cannot create a TLS session");
  SSL_set_fd(ssl, sock);
  X509_VERIFY_PARAM *param = SSL_get0_param(ssl);
  X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
  if (X509_VERIFY_PARAM_set1_ip_asc(param, host) != 1) {
    /* not an IP literal: verify it as a DNS name and send it as SNI */
    if (SSL_set1_host(ssl, host) != 1) die(EX_CONNECT, "invalid host name");
    SSL_set_tlsext_host_name(ssl, host);
  }
  if (SSL_connect(ssl) != 1) {
    long v = SSL_get_verify_result(ssl);
    if (v != X509_V_OK)
      die(EX_CONNECT, "TLS verification failed: %s", X509_verify_cert_error_string(v));
    die(EX_CONNECT, "TLS handshake failed");
  }
  /* SSL_VERIFY_PEER already aborts on failure; check again explicitly. */
  X509 *peer = SSL_get1_peer_certificate(ssl);
  if (!peer || SSL_get_verify_result(ssl) != X509_V_OK)
    die(EX_CONNECT, "TLS verification failed: no verified peer certificate");
  X509_free(peer);
}

/* ---- credentials ------------------------------------------------------- */

static const char *user = NULL, *pass = NULL;

static void load_credentials(void) {
  user = getenv("MAILBEND_EMAIL");
  pass = getenv("MAILBEND_APP_PASSWORD");
  if (!user || !*user) die(EX_USAGE, "MAILBEND_EMAIL is not set");
  if (!pass || !*pass) die(EX_USAGE, "MAILBEND_APP_PASSWORD is not set");
  for (const char *s = user; *s; s++)
    if ((unsigned char)*s < 0x21 || (unsigned char)*s > 0x7E)
      die(EX_USAGE, "MAILBEND_EMAIL must be printable ASCII without spaces");
  for (const char *s = pass; *s; s++)
    if ((unsigned char)*s < 0x20 || (unsigned char)*s > 0x7E)
      die(EX_USAGE, "MAILBEND_APP_PASSWORD must be printable ASCII");
}

/* Appends s as an IMAP quoted string. */
static size_t put_quoted(char *dst, const char *s) {
  size_t n = 0;
  dst[n++] = '"';
  for (; *s; s++) {
    if (*s == '"' || *s == '\\') dst[n++] = '\\';
    dst[n++] = *s;
  }
  dst[n++] = '"';
  return n;
}

static void wipe(void *p, size_t n) { OPENSSL_cleanse(p, n); }

/* ---- stdin ------------------------------------------------------------- */

static unsigned char *in = NULL;
static size_t in_len = 0;

static void read_stdin(void) {
  size_t cap = 65536;
  in = malloc(cap);
  if (!in) die(EX_PROTO, "out of memory");
  for (;;) {
    if (in_len == cap) {
      if (cap >= MAX_SCRIPT) die(EX_USAGE, "command script exceeds the input limit");
      cap *= 2;
      in = realloc(in, cap);
      if (!in) die(EX_PROTO, "out of memory");
    }
    ssize_t r = read(0, in + in_len, cap - in_len);
    if (r < 0 && errno == EINTR) continue;
    if (r < 0) die(EX_USAGE, "cannot read the command script");
    if (r == 0) break;
    in_len += (size_t)r;
  }
}

/* ---- IMAP -------------------------------------------------------------- */

enum { ST_OK, ST_NO, ST_BAD, ST_CONT, ST_BYE };

/* If the line ends in "{N}\r\n", returns 1 and stores N. (Non-synchronizing
 * "{N+}" literals are neither sent by MailBend nor accepted from servers.) */
static int literal_len(const unsigned char *l, long n, unsigned long long *out) {
  if (n < 4 || l[n - 1] != '\n' || l[n - 2] != '\r' || l[n - 3] != '}') return 0;
  long i = n - 4;
  long end = i;
  while (i >= 0 && isdigit(l[i])) i--;
  if (i < 0 || l[i] != '{' || i == end) return 0;
  unsigned long long v = 0;
  for (long k = i + 1; k <= end; k++) {
    v = v * 10 + (unsigned long long)(l[k] - '0');
    if (v > MAX_LITERAL) die(EX_PROTO, "literal exceeds the literal limit");
  }
  *out = v;
  return 1;
}

static int status_word(const unsigned char *p) {
  if (strncasecmp((const char *)p, "OK", 2) == 0 && (p[2] == ' ' || p[2] == '\r')) return ST_OK;
  if (strncasecmp((const char *)p, "NO", 2) == 0 && (p[2] == ' ' || p[2] == '\r')) return ST_NO;
  return ST_BAD;
}

/* Reads server responses, copying them to stdout, until the tagged answer
 * for `tag` (returns its status), or a continuation request when
 * `want_cont` (returns ST_CONT). Literals inside responses are copied as raw
 * bytes, so message content can never be mistaken for a tagged answer. */
static int imap_wait(const char *tag, int want_cont) {
  size_t tl = strlen(tag);
  for (;;) {
    unsigned char *line;
    long n = read_line(&line);
    if (n < 0) return ST_BYE;
    if (line[0] == '+' && (n == 1 || line[1] == ' ' || line[1] == '\r')) {
      free(line);
      if (want_cont) return ST_CONT;
      die(EX_PROTO, "unexpected continuation request");
    }
    emit(line, (size_t)n);
    if (line[0] == '*') {
      /* an untagged line may carry literals; each is followed by more line */
      /* (after "* BYE" the tagged answer or end of stream follows) */
      unsigned long long lit;
      unsigned char *cur = line;
      long cn = n;
      while (literal_len(cur, cn, &lit)) {
        if (cur != line) free(cur);
        pass_bytes(lit);
        cn = read_line(&cur);
        if (cn < 0) die(EX_PROTO, "connection closed after a literal");
        emit(cur, (size_t)cn);
      }
      if (cur != line) free(cur);
      free(line);
      continue;
    }
    if ((size_t)n > tl + 1 && memcmp(line, tag, tl) == 0 && line[tl] == ' ') {
      int st = status_word(line + tl + 1);
      free(line);
      return st;
    }
    free(line);
    die(EX_PROTO, "unexpected server line");
  }
}

static int valid_tag(const unsigned char *p, size_t n) {
  if (n == 0 || n > 16) return 0;
  for (size_t i = 0; i < n; i++)
    if (!isalnum(p[i])) return 0;
  if (n == 1 && (p[0] == 'L' || p[0] == 'Z')) return 0;
  return 1;
}

static int is_verb(const unsigned char *p, size_t n, const char *verb) {
  size_t vl = strlen(verb);
  return n >= vl && strncasecmp((const char *)p, verb, vl) == 0 &&
         (n == vl || p[vl] == ' ' || p[vl] == '\r');
}

/* Checks the command starting at `p` (tag, verb, CRLF lines, literal
 * bounds), stores its tag, and returns the offset just past it. */
static size_t imap_command(size_t p, char tag[17]) {
  unsigned char *nl = memchr(in + p, '\n', in_len - p);
  if (!nl) die(EX_USAGE, "command script does not end in CRLF");
  size_t first_len = (size_t)(nl - (in + p)) + 1;
  unsigned char *sp = memchr(in + p, ' ', first_len);
  if (!sp) die(EX_USAGE, "command without a tag");
  size_t tl = (size_t)(sp - (in + p));
  if (!valid_tag(in + p, tl)) die(EX_USAGE, "invalid or reserved command tag");
  size_t rest = first_len - tl - 1;
  if (is_verb(sp + 1, rest, "LOGIN") || is_verb(sp + 1, rest, "AUTHENTICATE") ||
      is_verb(sp + 1, rest, "STARTTLS") || is_verb(sp + 1, rest, "LOGOUT"))
    die(EX_USAGE, "the script may not authenticate or log out");
  memcpy(tag, in + p, tl);
  tag[tl] = 0;
  for (;;) {
    nl = memchr(in + p, '\n', in_len - p);
    if (!nl) die(EX_USAGE, "command script does not end in CRLF");
    size_t ln = (size_t)(nl - (in + p)) + 1;
    if (ln < 2 || in[p + ln - 2] != '\r') die(EX_USAGE, "command lines must end in CRLF");
    unsigned long long lit;
    int has_lit = literal_len(in + p, (long)ln, &lit);
    p += ln;
    if (!has_lit) return p;
    if (lit > in_len - p) die(EX_USAGE, "literal runs past the end of the script");
    p += (size_t)lit;
  }
}

/* Validates the whole script before connecting, so a malformed later
 * command can never be found only after earlier ones have run. */
static void imap_validate(void) {
  char tag[17];
  for (size_t p = 0; p < in_len;) p = imap_command(p, tag);
}

static int run_imap(void) {
  const char *host = env_or("MAILBEND_IMAP_HOST", "imap.mail.me.com");
  const char *port = env_or("MAILBEND_IMAP_PORT", "993");
  int timeout = atoi(env_or("MAILBEND_TIMEOUT_MS", "30000"));
  if (timeout <= 0) timeout = 30000;

  load_credentials();
  read_stdin();
  imap_validate();
  tcp_connect(host, port, timeout);
  tls_start(host);

  unsigned char *g;
  long gn = read_line(&g);
  if (gn < 0) die(EX_PROTO, "no greeting");
  emit(g, (size_t)gn);
  int preauth = strncasecmp((const char *)g, "* PREAUTH", 9) == 0;
  if (!preauth && strncasecmp((const char *)g, "* OK", 4) != 0)
    die(EX_PROTO, "server refused the connection");
  free(g);

  if (!preauth) {
    size_t cap = 32 + 2 * (strlen(user) + strlen(pass));
    char *cmd = malloc(cap);
    if (!cmd) die(EX_PROTO, "out of memory");
    size_t n = 0;
    memcpy(cmd + n, "L LOGIN ", 8); n += 8;
    n += put_quoted(cmd + n, user);
    cmd[n++] = ' ';
    n += put_quoted(cmd + n, pass);
    cmd[n++] = '\r';
    cmd[n++] = '\n';
    raw_write(cmd, n);
    wipe(cmd, cap);
    free(cmd);
    int st = imap_wait("L", 0);
    if (st != ST_OK) die(EX_AUTH, "IMAP login rejected");
  }

  int status = EX_OK;
  size_t p = 0;
  while (p < in_len) {
    char tag[17];
    size_t end = imap_command(p, tag);
    int st = ST_OK;
    while (p < end) {
      unsigned char *nl = memchr(in + p, '\n', end - p);
      size_t ln = (size_t)(nl - (in + p)) + 1;
      unsigned long long lit;
      int has_lit = literal_len(in + p, (long)ln, &lit);
      raw_write(in + p, ln);
      p += ln;
      if (!has_lit) {
        st = imap_wait(tag, 0);
        break;
      }
      st = imap_wait(tag, 1);
      if (st == ST_OK) die(EX_PROTO, "server completed a command before its literal was sent");
      if (st != ST_CONT) break; /* the server refused the literal */
      raw_write(in + p, (size_t)lit);
      p += (size_t)lit;
    }
    if (st == ST_BYE) die(EX_PROTO, "server closed the connection");
    if (st != ST_OK) {
      fprintf(stderr, "mailbend-tls: command %s rejected; later commands skipped\n", tag);
      status = EX_REJECTED;
      break;
    }
  }

  raw_write("Z LOGOUT\r\n", 10);
  imap_wait("Z", 0);
  return status;
}

/* ---- SMTP -------------------------------------------------------------- */

/* Reads one (possibly multi-line) reply, copying it to stdout. Returns the
 * reply code; when `ext` is non-NULL it receives every line of the reply. */
static int smtp_reply(char **ext) {
  size_t cap = 1, n = 0;
  char *all = ext ? calloc(1, 1) : NULL;
  for (;;) {
    unsigned char *line;
    long ln = read_line(&line);
    if (ln < 0) die(EX_PROTO, "connection closed while waiting for a reply");
    emit(line, (size_t)ln);
    if (ln < 4 || !isdigit(line[0]) || !isdigit(line[1]) || !isdigit(line[2]))
      die(EX_PROTO, "malformed SMTP reply");
    int code = (line[0] - '0') * 100 + (line[1] - '0') * 10 + (line[2] - '0');
    if (ext) {
      cap += (size_t)ln;
      all = realloc(all, cap);
      if (!all) die(EX_PROTO, "out of memory");
      memcpy(all + n, line, (size_t)ln);
      n += (size_t)ln;
      all[n] = 0;
    }
    int more = line[3] == '-';
    free(line);
    if (!more) {
      if (ext) *ext = all;
      return code;
    }
  }
}

static void smtp_send(const char *s) { raw_write(s, strlen(s)); }

static int has_ext(const char *ehlo, const char *word) {
  size_t wl = strlen(word);
  for (const char *l = ehlo; *l;) {
    const char *e = strchr(l, '\n');
    size_t n = e ? (size_t)(e - l) : strlen(l);
    /* "250-WORD ..." or "250 WORD ..." */
    if (n > 4 + wl && strncasecmp(l + 4, word, wl) == 0 &&
        (l[4 + wl] == ' ' || l[4 + wl] == '\r' || l[4 + wl] == '\n'))
      return 1;
    if (n >= 4 + wl && strncasecmp(l + 4, word, wl) == 0 && n == 4 + wl) return 1;
    if (!e) break;
    l = e + 1;
  }
  return 0;
}

/* True when the AUTH extension line lists `mech`. */
static int has_auth(const char *ehlo, const char *mech) {
  size_t ml = strlen(mech);
  for (const char *l = ehlo; *l;) {
    const char *e = strchr(l, '\n');
    size_t n = e ? (size_t)(e - l) : strlen(l);
    if (n > 9 && strncasecmp(l + 4, "AUTH ", 5) == 0) {
      for (size_t i = 9; i + ml <= n; i++) {
        int start = l[i - 1] == ' ';
        char after = i + ml < n ? l[i + ml] : ' ';
        if (start && strncasecmp(l + i, mech, ml) == 0 &&
            (after == ' ' || after == '\r' || after == '\n'))
          return 1;
      }
    }
    if (!e) break;
    l = e + 1;
  }
  return 0;
}

static char *b64(const unsigned char *p, size_t n) {
  char *o = malloc(4 * ((n + 2) / 3) + 1);
  if (!o) die(EX_PROTO, "out of memory");
  EVP_EncodeBlock((unsigned char *)o, p, (int)n);
  return o;
}

static void smtp_auth(const char *ehlo) {
  if (has_auth(ehlo, "PLAIN")) {
    size_t ul = strlen(user), pl = strlen(pass), n = ul + pl + 2;
    unsigned char *raw = malloc(n);
    if (!raw) die(EX_PROTO, "out of memory");
    raw[0] = 0;
    memcpy(raw + 1, user, ul);
    raw[1 + ul] = 0;
    memcpy(raw + 2 + ul, pass, pl);
    char *enc = b64(raw, n);
    size_t el = strlen(enc);
    char *cmd = malloc(el + 16);
    if (!cmd) die(EX_PROTO, "out of memory");
    int cl = snprintf(cmd, el + 16, "AUTH PLAIN %s\r\n", enc);
    raw_write(cmd, (size_t)cl);
    wipe(raw, n); wipe(enc, el); wipe(cmd, el + 16);
    free(raw); free(enc); free(cmd);
  } else if (has_auth(ehlo, "LOGIN")) {
    smtp_send("AUTH LOGIN\r\n");
    if (smtp_reply(NULL) != 334) die(EX_AUTH, "SMTP AUTH LOGIN refused");
    char *u = b64((const unsigned char *)user, strlen(user));
    raw_write(u, strlen(u)); raw_write("\r\n", 2); free(u);
    if (smtp_reply(NULL) != 334) die(EX_AUTH, "SMTP AUTH LOGIN refused");
    char *pw = b64((const unsigned char *)pass, strlen(pass));
    size_t pl = strlen(pw);
    raw_write(pw, pl); raw_write("\r\n", 2);
    wipe(pw, pl); free(pw);
  } else {
    die(EX_AUTH, "server offers neither AUTH PLAIN nor AUTH LOGIN");
  }
  if (smtp_reply(NULL) != 235) die(EX_AUTH, "SMTP authentication rejected");
}

/* Validates the whole envelope before connecting: CRLF lines, none of the
 * helper's own verbs, and a message that ends in a "." line after DATA. */
static void smtp_validate(void) {
  int in_data = 0;
  for (size_t p = 0; p < in_len;) {
    unsigned char *nl = memchr(in + p, '\n', in_len - p);
    if (!nl) die(EX_USAGE, "envelope does not end in CRLF");
    size_t ln = (size_t)(nl - (in + p)) + 1;
    if (ln < 2 || in[p + ln - 2] != '\r') die(EX_USAGE, "envelope lines must end in CRLF");
    if (in_data) {
      if (ln == 3 && in[p] == '.') in_data = 0;
    } else if (is_verb(in + p, ln, "AUTH") || is_verb(in + p, ln, "STARTTLS") ||
               is_verb(in + p, ln, "EHLO") || is_verb(in + p, ln, "HELO") ||
               is_verb(in + p, ln, "QUIT")) {
      die(EX_USAGE, "the envelope may not greet, authenticate or quit");
    } else if (is_verb(in + p, ln, "DATA")) {
      in_data = 1;
    }
    p += ln;
  }
  if (in_data) die(EX_USAGE, "message does not end in a \".\" line");
}

static int run_smtp(void) {
  const char *host = env_or("MAILBEND_SMTP_HOST", "smtp.mail.me.com");
  const char *port = env_or("MAILBEND_SMTP_PORT", "587");
  int timeout = atoi(env_or("MAILBEND_TIMEOUT_MS", "30000"));
  if (timeout <= 0) timeout = 30000;

  load_credentials();
  read_stdin();
  smtp_validate();
  tcp_connect(host, port, timeout);

  if (smtp_reply(NULL) != 220) die(EX_PROTO, "server refused the connection");
  char *ehlo = NULL;
  smtp_send("EHLO [127.0.0.1]\r\n");
  if (smtp_reply(&ehlo) != 250) die(EX_PROTO, "EHLO rejected");
  if (!has_ext(ehlo, "STARTTLS")) die(EX_CONNECT, "server does not offer STARTTLS");
  free(ehlo);
  smtp_send("STARTTLS\r\n");
  if (smtp_reply(NULL) != 220) die(EX_CONNECT, "STARTTLS refused");
  if (rpos != rlen) die(EX_PROTO, "server sent data before the TLS handshake");
  tls_start(host);
  smtp_send("EHLO [127.0.0.1]\r\n");
  if (smtp_reply(&ehlo) != 250) die(EX_PROTO, "EHLO after STARTTLS rejected");
  smtp_auth(ehlo);
  free(ehlo);

  int status = EX_OK;
  size_t p = 0;
  while (p < in_len && status == EX_OK) {
    unsigned char *nl = memchr(in + p, '\n', in_len - p);
    if (!nl) die(EX_USAGE, "envelope does not end in CRLF");
    size_t ln = (size_t)(nl - (in + p)) + 1;
    if (ln < 2 || in[p + ln - 2] != '\r') die(EX_USAGE, "envelope lines must end in CRLF");
    if (is_verb(in + p, ln, "AUTH") || is_verb(in + p, ln, "STARTTLS") ||
        is_verb(in + p, ln, "EHLO") || is_verb(in + p, ln, "HELO") ||
        is_verb(in + p, ln, "QUIT"))
      die(EX_USAGE, "the envelope may not greet, authenticate or quit");
    int data = is_verb(in + p, ln, "DATA");
    raw_write(in + p, ln);
    p += ln;
    int code = smtp_reply(NULL);
    if (!data) {
      if (code / 100 != 2) status = EX_REJECTED;
      continue;
    }
    if (code != 354) { status = EX_REJECTED; break; }
    /* the message, through the terminating "." line */
    int ended = 0;
    while (p < in_len) {
      nl = memchr(in + p, '\n', in_len - p);
      if (!nl) die(EX_USAGE, "message does not end in CRLF");
      ln = (size_t)(nl - (in + p)) + 1;
      if (ln < 2 || in[p + ln - 2] != '\r') die(EX_USAGE, "message lines must end in CRLF");
      raw_write(in + p, ln);
      int dot = ln == 3 && in[p] == '.';
      p += ln;
      if (dot) { ended = 1; break; }
    }
    if (!ended) die(EX_USAGE, "message does not end in a \".\" line");
    if (smtp_reply(NULL) / 100 != 2) status = EX_REJECTED;
  }
  if (status != EX_OK) fputs("mailbend-tls: SMTP command rejected\n", stderr);
  smtp_send("QUIT\r\n");
  unsigned char *line;
  long n;
  while ((n = read_line(&line)) >= 0) {
    emit(line, (size_t)n);
    int last = n < 4 || line[3] != '-';
    free(line);
    if (last) break;
  }
  return status;
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  if (argc != 2) die(EX_USAGE, "usage: mailbend-tls imap|smtp");
  int r = EX_USAGE;
  if (strcmp(argv[1], "imap") == 0) r = run_imap();
  else if (strcmp(argv[1], "smtp") == 0) r = run_smtp();
  else die(EX_USAGE, "usage: mailbend-tls imap|smtp");
  fflush(stdout);
  if (in) { wipe(in, in_len); free(in); }
  return r;
}
