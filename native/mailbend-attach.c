/*
 * mailbend-attach: reads one attachment for MailBend, safely.
 *
 *   mailbend-attach <dir> <path> <max-bytes>   > file bytes
 *
 * Kept apart from mailbend-tls so the credential-bearing helper never reads
 * files: this program opens no connection, and it clears its environment
 * before anything else, so the app password it may have inherited is gone
 * before a caller-chosen path is touched.
 *
 * <path> is relative to <dir>, or absolute inside it. <dir> is resolved once
 * with realpath() and opened by that canonical path with
 * RESOLVE_NO_SYMLINKS, so a component swapped for a symlink afterwards is
 * refused. The file is opened beneath it with openat2(RESOLVE_BENEATH |
 * RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS), so no symlink or ".." leads
 * outside, and only a regular file of at most <max-bytes> (never more than
 * 25 MiB) is read, checked on the opened descriptor itself.
 *
 * stdout: the file's bytes, each byte 0x80-0xFF written as the UTF-8
 * encoding of U+0080-U+00FF (the same encoding as mailbend-tls), so the Bend
 * side reads one character per byte.
 *
 * Exit status: 0 ok, 2 refused or unreadable (the reason is on stderr).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/openat2.h>

#define EX_REFUSED 2
#define MAX_ATTACHMENT (25ull << 20)

__attribute__((noreturn, format(printf, 1, 2)))
static void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fputs("mailbend-attach: ", stderr);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  exit(EX_REFUSED);
}

static void emit(const unsigned char *p, size_t n) {
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

static int open2(int dirfd, const char *path, unsigned long long flags, unsigned long long resolve) {
  struct open_how how;
  memset(&how, 0, sizeof how);
  how.flags = flags;
  how.resolve = resolve;
  return (int)syscall(SYS_openat2, dirfd, path, &how, sizeof how);
}

static unsigned long long parse_max(const char *s) {
  char *end;
  errno = 0;
  unsigned long long v = strtoull(s, &end, 10);
  if (errno || end == s || *end || v == 0) die("bad byte limit %s", s);
  return v < MAX_ATTACHMENT ? v : MAX_ATTACHMENT;
}

int main(int argc, char **argv) {
  clearenv();
  if (argc != 4) die("usage: mailbend-attach <dir> <path> <max-bytes>");
  const char *dir = argv[1], *path = argv[2];
  unsigned long long max = parse_max(argv[3]);

  char root[PATH_MAX];
  if (!realpath(dir, root)) die("MAILBEND_ATTACH_DIR does not exist");
  const char *rel = path;
  if (path[0] == '/') {
    size_t rl = strlen(root), dl = strlen(dir);
    while (dl > 1 && dir[dl - 1] == '/') dl--;
    if (strncmp(path, root, rl) == 0 && path[rl] == '/') rel = path + rl + 1;
    else if (strncmp(path, dir, dl) == 0 && path[dl] == '/') rel = path + dl + 1;
    else die("attachment %s is outside MAILBEND_ATTACH_DIR", path);
  }
  if (!*rel) die("attachment path names no file");

  /* `root` is canonical, so it holds no symlink; opening it with
   * RESOLVE_NO_SYMLINKS fails if a component was swapped for one since
   * realpath() read it. */
  int dfd = open2(AT_FDCWD, root, O_RDONLY | O_DIRECTORY | O_CLOEXEC,
                  RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS);
  if (dfd < 0) {
    if (errno == ENOSYS) die("attachments need Linux 5.6+ (openat2)");
    if (errno == ELOOP) die("MAILBEND_ATTACH_DIR changed while it was opened");
    die("cannot open MAILBEND_ATTACH_DIR");
  }
  int fd = open2(dfd, rel, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY,
                 RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS);
  if (fd < 0) {
    if (errno == ENOENT) die("attachment not found: %s", path);
    if (errno == EXDEV || errno == ELOOP)
      die("attachment %s is outside MAILBEND_ATTACH_DIR or reached through a symlink", path);
    die("cannot open attachment %s: %s", path, strerror(errno));
  }
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) die("attachment %s is not a regular file", path);
  if ((unsigned long long)st.st_size > max) die("attachments would exceed %llu bytes (at %s)", max, path);

  unsigned char buf[65536];
  unsigned long long total = 0;
  for (;;) {
    ssize_t r = read(fd, buf, sizeof buf);
    if (r < 0 && errno == EINTR) continue;
    if (r < 0) die("cannot read attachment %s", path);
    if (r == 0) break;
    total += (unsigned long long)r;
    if (total > max) die("attachments would exceed %llu bytes (at %s)", max, path);
    emit(buf, (size_t)r);
  }
  close(fd);
  close(dfd);
  if (fflush(stdout) != 0) die("cannot write the attachment");
  return 0;
}
