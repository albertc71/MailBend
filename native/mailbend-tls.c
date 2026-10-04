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
 * the next one. A line "=EXPECT <text>" right after a command is not sent:
 * it makes the run stop (like a rejection) unless one of that command's
 * untagged response lines starts with <text>. "=EXPECT-WORD <word>" asks
 * instead for <word> as a whole word (case-insensitive) in one of those
 * lines. The Bend core uses them to pin UIDVALIDITY and to confirm an
 * extension (such as UIDPLUS) in the same session that changes messages.
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
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <curl/curl.h>
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
/* Kept alive while OpenSSL uses the connected socket owned by libcurl. */
static CURL *connection = NULL;
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

static int configured_timeout_ms(void) {
  int timeout = atoi(env_or("MAILBEND_TIMEOUT_MS", "30000"));
  return timeout > 0 ? timeout : 30000;
}

/* ---- output ------------------------------------------------------------ */

/* Set while authenticating: those replies are consumed, never forwarded, so
 * a server that echoes the credentials cannot pass them to the core. */
static int quiet = 0;

static void emit(const unsigned char *p, size_t n) {
  if (quiet) return;
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
/* Like raw_write, but reports failure instead of exiting: for the closing
 * LOGOUT and QUIT, which must not replace the outcome of the commands that
 * already ran with a transport error. */
static int try_write(const char *s) {
  size_t n = strlen(s);
  const unsigned char *b = (const unsigned char *)s;
  while (n > 0) {
    int w = SSL_write(ssl, b, n > 65536 ? 65536 : (int)n);
    if (w <= 0) return 0;
    b += w;
    n -= (size_t)w;
  }
  return 1;
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

static void curl_check(CURLcode code) {
  if (code != CURLE_OK)
    die(EX_CONNECT, "cannot configure the resolver/connection: %s",
        curl_easy_strerror(code));
}

static CURLU *mail_connection_url(const char *host, const char *port) {
  CURLU *url = curl_url();
  if (!url) die(EX_CONNECT, "cannot create a connection URL");
  /* URL syntax needs brackets around IPv6. The caller keeps the original
   * host unchanged for mail certificate verification and SNI. */
  unsigned char host_ip[16];
  char bracketed[INET6_ADDRSTRLEN + 2];
  const char *url_host = host;
  if (inet_pton(AF_INET6, host, host_ip) == 1) {
    snprintf(bracketed, sizeof bracketed, "[%s]", host);
    url_host = bracketed;
  }
  /* HTTP is only a URL container here: CONNECT_ONLY sends no HTTP or mail
   * bytes. The existing OpenSSL/IMAP/SMTP code owns every protocol byte. */
  if (curl_url_set(url, CURLUPART_SCHEME, "http", 0) ||
      curl_url_set(url, CURLUPART_HOST, url_host, 0) ||
      curl_url_set(url, CURLUPART_PORT, port, 0))
    die(EX_USAGE, "invalid mail host or port");
  return url;
}

/* The returned list is borrowed by libcurl until the connection attempt ends.
 * A numeric override wins over DoH; neither changes the mail TLS identity. */
static struct curl_slist *configure_connection_route(
    CURL *handle, const char *port, const char *connect_ip_env,
    const char *connect_ip, const char *doh_url) {
  struct curl_slist *route_entries = NULL;
  if (*connect_ip) {
    unsigned char bytes[16];
    int is_ipv6 = inet_pton(AF_INET6, connect_ip, bytes) == 1;
    if (!is_ipv6 && inet_pton(AF_INET, connect_ip, bytes) != 1)
      die(EX_USAGE, "%s must be one numeric IPv4 or IPv6 address", connect_ip_env);
    char *entry = NULL;
    /* CONNECT_TO is source-host:source-port:destination-host:destination-port.
     * Empty source fields match this connection's original host and port. */
    if (asprintf(&entry, "::%s%s%s:%s", is_ipv6 ? "[" : "", connect_ip,
                 is_ipv6 ? "]" : "", port) < 0)
      die(EX_CONNECT, "out of memory");
    route_entries = curl_slist_append(NULL, entry);
    free(entry);
    if (!route_entries) die(EX_CONNECT, "out of memory");
    curl_check(curl_easy_setopt(handle, CURLOPT_CONNECT_TO, route_entries));
  } else if (*doh_url) {
    /* Bootstrap the default resolver without consulting broken system DNS.
     * These are resolver anycast addresses, never pinned Apple addresses. */
    route_entries = curl_slist_append(NULL,
        "cloudflare-dns.com:443:1.1.1.1,1.0.0.1");
    if (!route_entries) die(EX_CONNECT, "out of memory");
    curl_check(curl_easy_setopt(handle, CURLOPT_RESOLVE, route_entries));
    curl_check(curl_easy_setopt(handle, CURLOPT_DOH_URL, doh_url));
    curl_check(curl_easy_setopt(handle, CURLOPT_DOH_SSL_VERIFYPEER, 1L));
    curl_check(curl_easy_setopt(handle, CURLOPT_DOH_SSL_VERIFYHOST, 2L));
    const char *ca = env_or("MAILBEND_CA_FILE", "");
    if (*ca) {
      curl_check(curl_easy_setopt(handle, CURLOPT_CAINFO, ca));
      curl_check(curl_easy_setopt(handle, CURLOPT_CAPATH, NULL));
    }
  }
  return route_entries;
}

/* Configure only the TCP connection; mail TLS and protocol stay below. */
static void configure_tcp_connection(CURL *handle, CURLU *url, int timeout_ms) {
  curl_check(curl_easy_setopt(handle, CURLOPT_CURLU, url));
  curl_check(curl_easy_setopt(handle, CURLOPT_CONNECT_ONLY, 1L));
  /* Raw mail sockets must never become an HTTP request through a proxy. */
  curl_check(curl_easy_setopt(handle, CURLOPT_PROXY, ""));
  curl_check(curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L));
  curl_check(curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT_MS, (long)timeout_ms));
  curl_check(curl_easy_setopt(handle, CURLOPT_TIMEOUT_MS, (long)timeout_ms));
}

static int connected_socket(CURL *handle, int timeout_ms) {
  curl_socket_t fd = CURL_SOCKET_BAD;
  curl_check(curl_easy_getinfo(handle, CURLINFO_ACTIVESOCKET, &fd));
  if (fd == CURL_SOCKET_BAD) die(EX_CONNECT, "no connected socket");
  /* Mail I/O uses blocking OpenSSL/socket calls with per-operation timeouts. */
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) < 0 ||
      fcntl(fd, F_SETFD, FD_CLOEXEC) < 0)
    die(EX_CONNECT, "cannot configure the connected socket");
  set_timeouts(fd, timeout_ms);
  return fd;
}

static void tcp_connect(const char *host, const char *port,
                        const char *connect_ip_env, int timeout_ms) {
  const char *doh_url = env_or("MAILBEND_DOH_URL", "");
  const char *connect_ip = env_or(connect_ip_env, "");
  if (*doh_url && strncmp(doh_url, "https://", 8) != 0)
    die(EX_USAGE, "MAILBEND_DOH_URL must be an HTTPS URL");

  curl_check(curl_global_init(CURL_GLOBAL_DEFAULT));
  connection = curl_easy_init();
  if (!connection) die(EX_CONNECT, "cannot create a connection");
  CURLU *url = mail_connection_url(host, port);
  configure_tcp_connection(connection, url, timeout_ms);
  struct curl_slist *route_entries = configure_connection_route(
      connection, port, connect_ip_env, connect_ip, doh_url);

  const char *resolver_mode = "system DNS";
  if (*connect_ip) resolver_mode = "connection IP override";
  else if (*doh_url) resolver_mode = "DNS-over-HTTPS";
  CURLcode result = curl_easy_perform(connection);
  curl_slist_free_all(route_entries);
  curl_url_cleanup(url);
  if (result != CURLE_OK)
    die(EX_CONNECT, "cannot connect to %s:%s (%s; %s)", host, port,
        resolver_mode, curl_easy_strerror(result));
  sock = connected_socket(connection, timeout_ms);
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
/* The pending expectation for the current command, and whether it was met. */
static const unsigned char *expect = NULL;
static size_t expect_len = 0;
static int expect_word = 0;
static int expect_seen = 0;

/* Whether the line holds `w` as a whole word, ignoring case. */
static int has_word(const unsigned char *l, size_t n, const unsigned char *w, size_t wl) {
  for (size_t i = 1; i + wl <= n; i++) {
    unsigned char after = i + wl < n ? l[i + wl] : ' ';
    if (l[i - 1] == ' ' && strncasecmp((const char *)l + i, (const char *)w, wl) == 0 &&
        (after == ' ' || after == '\r' || after == '\n' || after == ']'))
      return 1;
  }
  return 0;
}

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
    if (line[0] == '*' && expect_len &&
        (expect_word ? has_word(line, (size_t)n, expect, expect_len)
                     : (size_t)n >= expect_len &&
                           strncasecmp((const char *)line, (const char *)expect, expect_len) == 0))
      expect_seen = 1;
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
 * bounds), stores its tag, sets *cmd_end to the end of the command itself
 * and *exp, *exp_len to a following "=EXPECT" text (or NULL, 0), and returns
 * the offset just past both. */
static size_t imap_command(size_t p, char tag[17], size_t *cmd_end, const unsigned char **exp, size_t *exp_len, int *exp_word) {
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
    if (!has_lit) break;
    if (lit > in_len - p) die(EX_USAGE, "literal runs past the end of the script");
    p += (size_t)lit;
  }
  *cmd_end = p;
  *exp = NULL;
  *exp_len = 0;
  *exp_word = 0;
  static const char word_dir[] = "=EXPECT-WORD ";
  static const char prefix_dir[] = "=EXPECT ";
  int word = in_len - p > sizeof word_dir - 1 && memcmp(in + p, word_dir, sizeof word_dir - 1) == 0;
  size_t dl = word ? sizeof word_dir - 1 : sizeof prefix_dir - 1;
  if (word || (in_len - p > dl && memcmp(in + p, prefix_dir, dl) == 0)) {
    nl = memchr(in + p, '\n', in_len - p);
    if (!nl) die(EX_USAGE, "command script does not end in CRLF");
    size_t ln = (size_t)(nl - (in + p)) + 1;
    if (ln < dl + 3 || in[p + ln - 2] != '\r') die(EX_USAGE, "an =EXPECT line needs text and CRLF");
    for (size_t i = p + dl; i < p + ln - 2; i++)
      if (in[i] < 0x20 || in[i] > 0x7E) die(EX_USAGE, "=EXPECT text must be printable ASCII");
    *exp = in + p + dl;
    *exp_len = ln - dl - 2;
    *exp_word = word;
    if (word && memchr(*exp, ' ', *exp_len)) die(EX_USAGE, "=EXPECT-WORD takes one word");
    p += ln;
  }
  return p;
}

/* Validates the whole script before connecting, so a malformed later
 * command can never be found only after earlier ones have run. */
static void imap_validate(void) {
  char tag[17];
  size_t cmd_end, el;
  const unsigned char *e;
  int ew;
  for (size_t p = 0; p < in_len;) p = imap_command(p, tag, &cmd_end, &e, &el, &ew);
}

static void imap_login(void) {
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
  quiet = 1;
  int st = imap_wait("L", 0);
  quiet = 0;
  if (st != ST_OK) die(EX_AUTH, "IMAP login rejected");
}

static int run_imap(void) {
  const char *host = env_or("MAILBEND_IMAP_HOST", "imap.mail.me.com");
  const char *port = env_or("MAILBEND_IMAP_PORT", "993");
  int timeout = configured_timeout_ms();

  load_credentials();
  read_stdin();
  imap_validate();
  tcp_connect(host, port, "MAILBEND_IMAP_CONNECT_IP", timeout);
  tls_start(host);

  unsigned char *g;
  long gn = read_line(&g);
  if (gn < 0) die(EX_PROTO, "no greeting");
  emit(g, (size_t)gn);
  int preauth = strncasecmp((const char *)g, "* PREAUTH", 9) == 0;
  if (!preauth && strncasecmp((const char *)g, "* OK", 4) != 0)
    die(EX_PROTO, "server refused the connection");
  free(g);

  if (!preauth) imap_login();

  int status = EX_OK;
  size_t p = 0;
  while (p < in_len) {
    char tag[17];
    size_t end, next = imap_command(p, tag, &end, &expect, &expect_len, &expect_word);
    expect_seen = 0;
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
    if (expect_len && !expect_seen) {
      fprintf(stderr, "mailbend-tls: command %s lacked the expected response \"%.*s\"; later commands skipped\n",
              tag, (int)expect_len, (const char *)expect);
      status = EX_REJECTED;
      break;
    }
    expect_len = 0;
    p = next;
  }

  /* LOGOUT is best effort: the commands' outcome is already known (after an
   * APPEND, reporting a failure here could lead to a duplicate draft). */
  if (try_write("Z LOGOUT\r\n")) {
    unsigned char *line;
    long n;
    while ((n = read_line(&line)) >= 0) {
      emit(line, (size_t)n);
      int done = n >= 2 && line[0] == 'Z' && line[1] == ' ';
      free(line);
      if (done) break;
    }
  }
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
  quiet = 1;
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
  quiet = 0;
}

static int smtp_reserved_verb(const unsigned char *line, size_t length) {
  return is_verb(line, length, "AUTH") || is_verb(line, length, "STARTTLS") ||
         is_verb(line, length, "EHLO") || is_verb(line, length, "HELO") ||
         is_verb(line, length, "QUIT");
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
    } else if (smtp_reserved_verb(in + p, ln)) {
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
  int timeout = configured_timeout_ms();

  load_credentials();
  read_stdin();
  smtp_validate();
  tcp_connect(host, port, "MAILBEND_SMTP_CONNECT_IP", timeout);

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

  int status = EX_OK, last = 0;
  size_t p = 0;
  while (p < in_len && status == EX_OK) {
    unsigned char *nl = memchr(in + p, '\n', in_len - p);
    if (!nl) die(EX_USAGE, "envelope does not end in CRLF");
    size_t ln = (size_t)(nl - (in + p)) + 1;
    if (ln < 2 || in[p + ln - 2] != '\r') die(EX_USAGE, "envelope lines must end in CRLF");
    if (smtp_reserved_verb(in + p, ln))
      die(EX_USAGE, "the envelope may not greet, authenticate or quit");
    int data = is_verb(in + p, ln, "DATA");
    raw_write(in + p, ln);
    p += ln;
    int code = smtp_reply(NULL);
    last = code;
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
    last = smtp_reply(NULL);
    if (last / 100 != 2) status = EX_REJECTED;
  }
  if (status != EX_OK) fputs("mailbend-tls: SMTP command rejected\n", stderr);
  /* QUIT is best effort: after a 421 the server has already closed, and a
   * failed QUIT must not turn the rejection into a transport error. */
  if (last != 421 && try_write("QUIT\r\n")) {
    unsigned char *line;
    long n;
    while ((n = read_line(&line)) >= 0) {
      emit(line, (size_t)n);
      int end = n < 4 || line[3] != '-';
      free(line);
      if (end) break;
    }
  }
  return status;
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  const curl_version_info_data *cv = curl_version_info(CURLVERSION_NOW);
  if (!cv || cv->version_num < 0x074c00 || !(cv->features & CURL_VERSION_SSL))
    die(EX_USAGE, "libcurl 7.76+ with HTTPS support is required");
  /* Credential-free readiness check for a rebuilt cloud computer. */
  if (argc == 2 && strcmp(argv[1], "--check") == 0) return EX_OK;
  int r = EX_USAGE;
  if (argc == 2 && strcmp(argv[1], "imap") == 0) r = run_imap();
  else if (argc == 2 && strcmp(argv[1], "smtp") == 0) r = run_smtp();
  else die(EX_USAGE, "usage: mailbend-tls imap|smtp|--check");
  fflush(stdout);
  if (in) { wipe(in, in_len); free(in); }
  SSL_free(ssl);
  curl_easy_cleanup(connection);
  curl_global_cleanup();
  return r;
}
