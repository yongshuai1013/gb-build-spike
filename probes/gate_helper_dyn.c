/* gate_helper_dyn - tiny DYNAMIC guest program (PT_INTERP =
 * /system/bin/linker). gate_smoke exec's it to exercise the compat
 * execve rewrite through gbexec and the guest linker. It writes a
 * marker file at the guest path in argv[1] and prints its (virtual)
 * pid, which also proves the dynamic libc came up gated. */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

int main(int argc, char **argv)
{
    int fd;
    char buf[64];
    int n;
    printf("gate_helper_dyn running, pid=%d\n", (int) getpid());
    fflush(stdout);
    if (argc < 2) return 2;
    fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return 3;
    n = snprintf(buf, sizeof(buf), "gate-helper-dyn pid=%d\n",
                 (int) getpid());
    if (write(fd, buf, n) < 0) { close(fd); return 4; }
    close(fd);
    return 0;
}
