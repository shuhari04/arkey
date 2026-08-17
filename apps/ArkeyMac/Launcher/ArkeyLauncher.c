#include <libgen.h>
#include <limits.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int executable_exists(const char *path) {
    return access(path, X_OK) == 0;
}

static const char *first_node(void) {
    static const char *candidates[] = {
        "/opt/homebrew/opt/node@22/bin/node",
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node",
        "/usr/bin/node",
        NULL
    };
    for (int i = 0; candidates[i] != NULL; i++) {
        if (executable_exists(candidates[i])) return candidates[i];
    }
    return NULL;
}

static void dirname_copy(const char *path, char *out, size_t out_size) {
    char buffer[PATH_MAX];
    snprintf(buffer, sizeof(buffer), "%s", path);
    snprintf(out, out_size, "%s", dirname(buffer));
}

int main(int argc, char **argv) {
    char macos_dir[PATH_MAX];
    char contents_dir[PATH_MAX];
    char real_binary[PATH_MAX];
    char cli[PATH_MAX];
    const char *node = first_node();

    dirname_copy(argv[0], macos_dir, sizeof(macos_dir));
    dirname_copy(macos_dir, contents_dir, sizeof(contents_dir));
    snprintf(real_binary, sizeof(real_binary), "%s/MacOS/ArkeyMac.bin", contents_dir);
    snprintf(cli, sizeof(cli), "%s/Resources/ArkeyRuntime/dist/src/cli.js", contents_dir);

    if (node != NULL && access(cli, R_OK) == 0) {
        pid_t pid;
        char *const repair_argv[] = {(char *)node, cli, "start", NULL};
        if (posix_spawn(&pid, node, NULL, NULL, repair_argv, environ) == 0) {
            int status = 0;
            waitpid(pid, &status, 0);
        }
    }

    execv(real_binary, argv);
    perror("exec ArkeyMac.bin");
    return 127;
}
