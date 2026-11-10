/* gated: filesystem unix-socket gate server for the GB guest host.
 *
 * Why a native helper: the public Android Java SDK cannot create a
 * filesystem unix-domain server socket (LocalServerSocket(String)
 * is abstract-namespace only; StructSockaddrUn / Os.bind are @hide).
 * The guest connects to $GBROOT/dev/socket/gate by path, so the
 * listener must be a real filesystem socket. This tiny POSIX helper
 * is built by CI with the NDK, bundled as an asset, extracted to
 * filesDir and exec'd/monitored/killed by GateService.
 *
 * Usage: gated <socket-path> <gate-log-path>
 * M1 protocol (per DESIGN-M1): line "PING" -> reply "PONG";
 * any other line is appended to the gate log as "CONSOLE <line>".
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/types.h>
#include <sys/wait.h>

static const char *g_log_path;

static void log_console(const char *line) {
    FILE *f = fopen(g_log_path, "a");
    if (!f) return;
    fprintf(f, "CONSOLE %s\n", line);
    fclose(f);
}

static void handle_client(int fd) {
    char buf[1024];
    size_t used = 0;
    for (;;) {
        if (used >= sizeof(buf) - 1) break;
        ssize_t n = read(fd, buf + used, sizeof(buf) - 1 - used);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (n == 0) break;
        used += (size_t)n;
        buf[used] = '\0';
        char *nl;
        while ((nl = strchr(buf, '\n')) != NULL) {
            *nl = '\0';
            size_t len = strlen(buf);
            while (len > 0 && buf[len - 1] == '\r') buf[--len] = '\0';
            if (strcmp(buf, "PING") == 0) {
                const char pong[] = "PONG\n";
                ssize_t w = write(fd, pong, sizeof(pong) - 1);
                (void)w;
            } else if (len > 0) {
                log_console(buf);
            }
            size_t rest = used - (size_t)(nl - buf) - 1;
            memmove(buf, nl + 1, rest);
            used = rest;
            buf[used] = '\0';
        }
    }
    if (used > 0) {
        buf[used] = '\0';
        if (strcmp(buf, "PING") == 0) {
            const char pong[] = "PONG\n";
            ssize_t w = write(fd, pong, sizeof(pong) - 1);
            (void)w;
        } else {
            log_console(buf);
        }
    }
    close(fd);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: gated <socket-path> <gate-log-path>\n");
        return 2;
    }
    const char *sock_path = argv[1];
    g_log_path = argv[2];

    signal(SIGCHLD, SIG_IGN); /* auto-reap per-client children */
    signal(SIGPIPE, SIG_IGN);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(sock_path) >= sizeof(addr.sun_path)) {
        fprintf(stderr, "socket path too long\n");
        return 1;
    }
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

    unlink(sock_path); /* stale socket from a previous run */
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    if (listen(fd, 16) < 0) { perror("listen"); return 1; }

    printf("gated listening at %s\n", sock_path);
    fflush(stdout);

    for (;;) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            return 1;
        }
        pid_t pid = fork();
        if (pid == 0) {
            close(fd);
            handle_client(c);
            _exit(0);
        }
        if (pid < 0) {
            /* fork failed: serve inline rather than dropping */
            handle_client(c);
        } else {
            close(c);
        }
    }
    return 0;
}
