#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Test-only OS boundary: replace date, leaving every other program alone. */
static const char *date_path(const char *path) {
    static unsigned calls;
    if (strcmp(path, "/bin/date")) return path;
    calls++;
    const char *log = getenv("CLOCK_TEST_LOG");
    FILE *out = log ? fopen(log, "a") : NULL;
    if (out) { fputs("date\n", out); fclose(out); }
    const char *mode = getenv("CLOCK_TEST_MODE");
    if (mode && (!strcmp(mode, "unavailable") ||
                 (!strcmp(mode, "second-unavailable") && calls > 1))) return NULL;
    const char *helper = getenv("CLOCK_TEST_HELPER");
    return helper ? helper : path;
}

int execve(const char *path, char *const argv[], char *const env[]) {
    const char *replacement = date_path(path);
    if (!replacement) { errno = ENOENT; return -1; }
    int (*real)(const char *, char *const[], char *const[]) = dlsym(RTLD_NEXT, "execve");
    return real(replacement, argv, env);
}

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                const posix_spawnattr_t *attr, char *const argv[], char *const env[]) {
    const char *replacement = date_path(path);
    if (!replacement) return ENOENT;
    int (*real)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                const posix_spawnattr_t *, char *const[], char *const[]) =
        dlsym(RTLD_NEXT, "posix_spawn");
    return real(pid, replacement, actions, attr, argv, env);
}

int posix_spawnp(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                 const posix_spawnattr_t *attr, char *const argv[], char *const env[]) {
    const char *replacement = date_path(path);
    if (!replacement) return ENOENT;
    int (*real)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                const posix_spawnattr_t *, char *const[], char *const[]) =
        dlsym(RTLD_NEXT, "posix_spawnp");
    return real(pid, replacement, actions, attr, argv, env);
}
