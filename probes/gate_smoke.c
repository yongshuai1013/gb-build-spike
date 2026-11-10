/*
 * gate_smoke - guest-side smoke test for the M1 compat layer.
 *
 * Run with GBROOT (and GBVPID) set, under qemu-user in CI or on the
 * device later. Prints one "SMOKE <name> OK/FAIL" line per check to
 * stdout. Exit status counts only the CORE checks (identity, path
 * translation, console, binder fake, fork vpid, gate counters): the
 * two exec checks are reported but not counted, because qemu-user's
 * guest execve re-execution is unreliable in some qemu builds (the
 * compat layer's execve *translation* is graded separately from the
 * QEMU_STRACE log in the CI report). On a real kernel both exec
 * checks are expected to pass as well.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>

extern unsigned int __gb_gate_pre_calls;
extern unsigned int __gb_gate_handled;
extern unsigned char __gb_gate_mode;

/* From libc/kernel/common/linux/binder.h (GB): BINDER_VERSION is
 * _IOWR('b', 9, struct binder_version) == 0xC0046209, protocol 7.
 * BINDER_WRITE_READ is _IOWR('b', 1, struct binder_write_read). */
#define GB_BINDER_VERSION_REQ 0xC0046209u
#define GB_BINDER_WRITE_READ_REQ 0xC0186201u

struct gb_binder_version { int protocol_version; };
struct gb_binder_write_read {
    signed long write_size;
    signed long write_consumed;
    unsigned long write_buffer;
    signed long read_size;
    signed long read_consumed;
    unsigned long read_buffer;
};

static int core_fails = 0;

static void report(const char *name, int ok, int core)
{
    printf("SMOKE %s %s\n", name, ok ? "OK" : "FAIL");
    fflush(stdout);
    if (!ok && core) core_fails++;
}

static int write_file(const char *path, const char *text)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    if (write(fd, text, strlen(text)) < 0) { close(fd); return -1; }
    close(fd);
    return 0;
}

int main(int argc, char **argv)
{
    const char *vpid_env = getenv("GBVPID");
    long want_vpid = vpid_env ? atol(vpid_env) : 0;

    printf("SMOKE start pid=%d mode=%d\n", getpid(), (int) __gb_gate_mode);
    fflush(stdout);

    report("gate_mode_on", __gb_gate_mode == 1, 1);
    report("getpid_virtual", want_vpid != 0 && getpid() == want_vpid, 1);
    report("getuid_zero", getuid() == 0 && geteuid() == 0, 1);

    report("write_data_file",
           write_file("/data/gate-smoke.txt", "gate-smoke-data\n") == 0, 1);

    {
        int fd = open("/dev/console", O_WRONLY | O_APPEND);
        int ok = 0;
        if (fd >= 0) {
            ok = write(fd, "gate-smoke-console\n", 19) == 19;
            close(fd);
        }
        report("write_console", ok, 1);
    }

    /* fork(): the child must claim GBVPID+1 as its virtual pid, and
     * the parent must receive the child's real pid. */
    {
        int p[2];
        int ok = 0;
        if (pipe(p) == 0) {
            pid_t pid = fork();
            if (pid == 0) {
                char buf[24];
                int n = snprintf(buf, sizeof(buf), "%d", (int) getpid());
                if (write(p[1], buf, n) < 0) { }
                _exit(0);
            }
            if (pid > 0) {
                char buf[24];
                int n = read(p[0], buf, sizeof(buf) - 1);
                int st = 0;
                if (n > 0) {
                    buf[n] = 0;
                    ok = atol(buf) == want_vpid + 1;
                }
                waitpid(pid, &st, 0);
            }
        }
        report("fork_vpid", ok, 1);
    }

    /* /dev/binder: dummy fd, faked version ioctl, and a
     * BINDER_WRITE_READ that parks the caller instead of failing. */
    {
        int fd = open("/dev/binder", O_RDWR);
        struct gb_binder_version ver;
        int ok = 0, park_ok = 0;
        ver.protocol_version = -1;
        if (fd >= 0) {
            ok = ioctl(fd, GB_BINDER_VERSION_REQ, &ver) == 0 &&
                 ver.protocol_version == 7;
            {
                pid_t pid = fork();
                if (pid == 0) {
                    struct gb_binder_write_read bwr;
                    memset(&bwr, 0, sizeof(bwr));
                    ioctl(fd, GB_BINDER_WRITE_READ_REQ, &bwr);
                    _exit(0); /* must never get here in M1 */
                }
                if (pid > 0) {
                    int st = 0;
                    usleep(300 * 1000);
                    park_ok = kill(pid, 0) == 0 &&
                              waitpid(pid, &st, WNOHANG) == 0;
                    kill(pid, SIGKILL);
                    waitpid(pid, &st, 0);
                }
            }
            close(fd);
        }
        report("binder_version", ok, 1);
        report("binder_write_read_parks", park_ok, 1);
    }

    /* exec of a static guest binary (path translation only). */
    {
        pid_t pid = fork();
        int st = 0, ok;
        if (pid == 0) {
            char *const a[] = { "gate_helper", "/data/gate-helper.txt", 0 };
            execve("/system/bin/gate_helper", a, environ);
            _exit(127);
        }
        waitpid(pid, &st, 0);
        ok = WIFEXITED(st) && WEXITSTATUS(st) == 0;
        report("exec_static", ok, 0);
    }

    /* exec of a dynamic guest binary (gbexec + guest linker chain). */
    {
        pid_t pid = fork();
        int st = 0, ok;
        if (pid == 0) {
            char *const a[] = { "gate_helper_dyn",
                                "/data/gate-helper-dyn.txt", 0 };
            execve("/system/bin/gate_helper_dyn", a, environ);
            _exit(127);
        }
        waitpid(pid, &st, 0);
        ok = WIFEXITED(st) && WEXITSTATUS(st) == 0;
        report("exec_dynamic_gbexec", ok, 0);
    }

    printf("SMOKE counters pre=%u handled=%u\n",
           __gb_gate_pre_calls, __gb_gate_handled);
    fflush(stdout);
    report("gate_counters", __gb_gate_pre_calls > 20 &&
           __gb_gate_handled >= 3, 1);

    printf("SMOKE DONE core_fails=%d\n", core_fails);
    fflush(stdout);
    return core_fails;
}
