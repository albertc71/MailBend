/*
 * mailbend-attach: reads one attachment for MailBend, safely.
 *
 *   mailbend-attach <dir> <path> <max-bytes>   > file bytes
 *
 * Kept apart from mailbend-tls so the credential-bearing helper never reads
 * files: this program opens no connection, and before anything else it
 * re-executes itself with an empty environment. (Clearing environ is not
 * enough: /proc/self/environ shows the environment the process started
 * with, which may hold the app password.) Files on procfs or sysfs are
 * refused as well.
 *
 * <path> is relative to <dir>, or absolute inside it. <dir> is resolved once
 * with realpath() and opened by that canonical path with
 * RESOLVE_NO_SYMLINKS, so a component swapped for a symlink afterwards is
 * refused. The file is opened beneath it with openat2(RESOLVE_BENEATH |
 * RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS), so no symlink or ".." leads
 * outside, and only a regular file of at most <max-bytes> (never more than
 * 25 MiB) is read, checked on the opened descriptor itself. The file's type
 * is checked on an O_PATH descriptor before it is opened for reading, so a
 * device or FIFO is never opened, and a file with more than one hard link is
 * refused (another name for it may live outside <dir>).
 *
 * <dir> must be a dedicated directory: "/", the user's home directory or any
 * directory containing it, and a directory holding .ssh, .gnupg, .aws,
 * .config or .git are refused, since every file inside <dir> can be mailed.
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
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/magic.h>
#include <linux/openat2.h>

extern char **environ;

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

static void drop_inherited_environment(char **argv) {
  if (environ && environ[0]) {
    char *empty[] = {NULL};
    execve("/proc/self/exe", argv, empty);
    die("cannot drop the inherited environment");
  }
}

static const char *relative_attachment_path(const char *dir, const char *root, const char *path) {
  const char *relative = path;
  if (path[0] == '/') {
    size_t root_length = strlen(root), dir_length = strlen(dir);
    while (dir_length > 1 && dir[dir_length - 1] == '/') dir_length--;
    if (strncmp(path, root, root_length) == 0 && path[root_length] == '/')
      relative = path + root_length + 1;
    else if (strncmp(path, dir, dir_length) == 0 && path[dir_length] == '/')
      relative = path + dir_length + 1;
    else die("attachment %s is outside MAILBEND_ATTACH_DIR", path);
  }
  if (!*relative) die("attachment path names no file");
  return relative;
}

static int open_attachment_directory(const char *root) {
  /* `root` is canonical, so it holds no symlink; opening it with
   * RESOLVE_NO_SYMLINKS fails if a component was swapped for one since
   * realpath() read it. */
  int fd = open2(AT_FDCWD, root, O_RDONLY | O_DIRECTORY | O_CLOEXEC,
                 RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS);
  if (fd < 0) {
    if (errno == ENOSYS) die("attachments need Linux 5.6+ (openat2)");
    if (errno == ELOOP) die("MAILBEND_ATTACH_DIR changed while it was opened");
    die("cannot open MAILBEND_ATTACH_DIR");
  }
  return fd;
}

/* Whether `outer` is `inner` or one of its parent directories (both canonical). */
static int contains_path(const char *outer, const char *inner) {
  size_t n = strlen(outer);
  if (n == 1 && outer[0] == '/') return 1;
  return strncmp(outer, inner, n) == 0 && (inner[n] == '\0' || inner[n] == '/');
}

/* Every file beneath the directory can be mailed, so it must not be one that
 * holds the user's keys or configuration. The home directory comes from the
 * password database: the environment is already gone. */
static void refuse_broad_directory(const char *root, int directory_fd) {
  if (strcmp(root, "/") == 0) die("MAILBEND_ATTACH_DIR must not be /: use a dedicated directory");
  struct passwd *pw = getpwuid(getuid());
  char home[PATH_MAX];
  if (pw && pw->pw_dir && realpath(pw->pw_dir, home) && contains_path(root, home))
    die("MAILBEND_ATTACH_DIR must not be your home directory or contain it: use a dedicated directory");
  static const char *const sensitive[] = {".ssh", ".gnupg", ".aws", ".config", ".git"};
  for (size_t i = 0; i < sizeof sensitive / sizeof *sensitive; i++) {
    struct stat st;
    if (fstatat(directory_fd, sensitive[i], &st, AT_SYMLINK_NOFOLLOW) == 0)
      die("MAILBEND_ATTACH_DIR holds %s, so it is not a dedicated attachment directory", sensitive[i]);
  }
}

static int open_beneath(int directory_fd, const char *relative, const char *path, unsigned long long flags) {
  int fd = open2(directory_fd, relative, flags | O_CLOEXEC,
                 RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS);
  if (fd < 0) {
    if (errno == ENOENT) die("attachment not found: %s", path);
    if (errno == EXDEV || errno == ELOOP)
      die("attachment %s is outside MAILBEND_ATTACH_DIR or reached through a symlink", path);
    die("cannot open attachment %s: %s", path, strerror(errno));
  }
  return fd;
}

/* Checks the file through an O_PATH descriptor (opening nothing), then opens
 * it for reading and makes sure it is still the same file. No O_NOFOLLOW on
 * the probe: with O_PATH it would return a final symlink itself instead of
 * letting RESOLVE_NO_SYMLINKS refuse it. */
static int open_attachment(int directory_fd, const char *relative, const char *path) {
  int probe = open_beneath(directory_fd, relative, path, O_PATH);
  struct stat before;
  if (fstat(probe, &before) != 0 || !S_ISREG(before.st_mode)) die("attachment %s is not a regular file", path);
  close(probe);
  int fd = open_beneath(directory_fd, relative, path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
  struct stat after;
  if (fstat(fd, &after) != 0 || after.st_dev != before.st_dev || after.st_ino != before.st_ino)
    die("attachment %s changed while it was opened", path);
  return fd;
}

static void validate_attachment(int fd, const char *path, unsigned long long max) {
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) die("attachment %s is not a regular file", path);
  if (st.st_nlink > 1) die("attachment %s has more than one hard link", path);
  struct statfs fs;
  if (fstatfs(fd, &fs) != 0 || fs.f_type == PROC_SUPER_MAGIC || fs.f_type == SYSFS_MAGIC)
    die("attachment %s is a kernel file (procfs or sysfs)", path);
  if ((unsigned long long)st.st_size > max) die("attachments would exceed %llu bytes (at %s)", max, path);
}

static void emit_attachment(int fd, const char *path, unsigned long long max) {
  unsigned char buf[65536];
  unsigned long long total = 0;
  for (;;) {
    ssize_t count = read(fd, buf, sizeof buf);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) die("cannot read attachment %s", path);
    if (count == 0) break;
    total += (unsigned long long)count;
    if (total > max) die("attachments would exceed %llu bytes (at %s)", max, path);
    emit(buf, (size_t)count);
  }
}

int main(int argc, char **argv) {
  drop_inherited_environment(argv);
  if (argc != 4) die("usage: mailbend-attach <dir> <path> <max-bytes>");
  const char *dir = argv[1], *path = argv[2];
  unsigned long long max = parse_max(argv[3]);

  char root[PATH_MAX];
  if (!realpath(dir, root)) die("MAILBEND_ATTACH_DIR does not exist");
  const char *relative = relative_attachment_path(dir, root, path);
  int directory_fd = open_attachment_directory(root);
  refuse_broad_directory(root, directory_fd);
  int fd = open_attachment(directory_fd, relative, path);
  validate_attachment(fd, path, max);
  emit_attachment(fd, path, max);
  close(fd);
  close(directory_fd);
  if (fflush(stdout) != 0) die("cannot write the attachment");
  return 0;
}
