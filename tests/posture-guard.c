#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

static void record(const char *kind) {
    const char *path = getenv("POSTURE_GUARD_LOG");
    if (path) {
        int fd = (int)syscall(SYS_openat, AT_FDCWD, path, O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (fd >= 0) {
            syscall(SYS_write, fd, kind, strlen(kind));
            syscall(SYS_write, fd, "\n", 1);
            syscall(SYS_close, fd);
        }
    }
}

static int secret(const char *path) {
    const char *password = getenv("MAILBEND_PASSWORD_FILE");
    const char *key = getenv("MAILBEND_TYPESAFE_KEY_FILE");
    if (path && ((password && !strcmp(path, password)) || (key && !strcmp(path, key)))) {
        record("secret-open");
        errno = EACCES;
        return 1;
    }
    return 0;
}

int open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list a; va_start(a, flags); mode = va_arg(a, mode_t); va_end(a); }
    if (secret(path)) return -1;
    int (*real)(const char *, int, ...) = dlsym(RTLD_NEXT, "open");
    return real(path, flags, mode);
}

int open64(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list a; va_start(a, flags); mode = va_arg(a, mode_t); va_end(a); }
    if (secret(path)) return -1;
    int (*real)(const char *, int, ...) = dlsym(RTLD_NEXT, "open64");
    return real(path, flags, mode);
}

int openat(int dir, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list a; va_start(a, flags); mode = va_arg(a, mode_t); va_end(a); }
    if (secret(path)) return -1;
    int (*real)(int, const char *, int, ...) = dlsym(RTLD_NEXT, "openat");
    return real(dir, path, flags, mode);
}

FILE *fopen(const char *path, const char *mode) {
    if (secret(path)) return NULL;
    FILE *(*real)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen");
    return real(path, mode);
}

FILE *fopen64(const char *path, const char *mode) {
    if (secret(path)) return NULL;
    FILE *(*real)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen64");
    return real(path, mode);
}

int socket(int domain, int type, int protocol) {
    (void)domain; (void)type; (void)protocol;
    record("socket"); errno = EACCES; return -1;
}

int connect(int fd, const struct sockaddr *addr, socklen_t len) {
    (void)fd; (void)addr; (void)len;
    record("connect"); errno = EACCES; return -1;
}

int execve(const char *path, char *const argv[], char *const env[]) {
    (void)path; (void)argv; (void)env;
    record("exec"); errno = EACCES; return -1;
}

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                const posix_spawnattr_t *attr, char *const argv[], char *const env[]) {
    (void)pid; (void)path; (void)actions; (void)attr; (void)argv; (void)env;
    record("spawn"); return EACCES;
}

int posix_spawnp(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                 const posix_spawnattr_t *attr, char *const argv[], char *const env[]) {
    return posix_spawn(pid, path, actions, attr, argv, env);
}
