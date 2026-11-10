/* gate_helper - tiny static guest program: writes a marker file at
 * the guest path given as argv[1]. Used by gate_smoke's exec checks
 * (and by the CI script running it directly under qemu). */
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
    if (argc < 2) return 2;
    fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return 3;
    n = snprintf(buf, sizeof(buf), "gate-helper pid=%d\n", (int) getpid());
    if (write(fd, buf, n) < 0) { close(fd); return 4; }
    close(fd);
    return 0;
}
