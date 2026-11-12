/*
 * gbexec - static trampoline that starts a dynamic guest executable
 * through the guest linker (M1, workline A).
 *
 * Why this exists: DESIGN-M1.md assumed the stock linker could be run
 * as "linker <program>", the way later Android linkers can. The GB
 * 2.3.7 linker cannot: bionic/linker/linker.c's __linker_init()
 * unconditionally treats the image identified by AT_PHDR / argv[0]
 * (i.e. the one the kernel loaded as the main program) as the
 * executable to link, and its main() is an empty stub. There is no
 * code path that looks at argv[1].
 *
 * So the compat execve() wrapper (gb_gate.c) rewrites an exec of a
 * PT_INTERP binary into an exec of this static trampoline instead:
 *
 *     execve("/system/bin/gbexec",
 *            {"/system/bin/gbexec", <guest target path>,
 *             <original argv[0]>, <original argv[1]>, ...}, env)
 *
 * gbexec then does the kernel's half of a dynamic exec by hand: it
 * maps the target's PT_LOAD segments at their link addresses, maps
 * /system/bin/linker at its link address (0xB0001000, ET_EXEC),
 * builds a kernel-style initial stack (argc/argv/envp/auxv with
 * AT_PHDR/AT_PHNUM/AT_BASE/AT_ENTRY describing the target) on a fresh
 * stack, and jumps to the linker's _start. From there the guest
 * linker loads the target's libraries (finding them through the
 * LD_LIBRARY_PATH the gate injected, which needs no translation
 * because the linker issues raw syscalls) exactly as if the kernel
 * had started the process.
 *
 * gbexec itself is linked at 0x10000000 (see Android.mk) so its own
 * image collides with neither the target (0x8000), the mmap area, the
 * linker (0xB0000000) nor the stack.
 *
 * All file access uses guest paths; this binary is linked against the
 * gate-patched static libc, so the compat layer translates them.
 */

#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

extern char **environ;

#define GBEXEC_STACK_SIZE (8 * 1024 * 1024)
#define GBEXEC_LINKER_BASE 0xB0000000u

static void gb_die(const char *msg)
{
    write(2, "gbexec: ", 8);
    write(2, msg, strlen(msg));
    write(2, "\n", 1);
    _exit(127);
}

/* Why the last gb_load() failed: the errno of the failing call,
 * captured at the failure point (before any cleanup could clobber
 * it), or a synthesized code for ELF sanity failures (ENOEXEC for
 * a bad ident, EINVAL for an out-of-bounds phdr table, EIO for a
 * short read). Telemetry only: the die lines name the path that
 * could not be loaded so a field log can tell which dynamic
 * binary's gbexec handoff failed (m1c field: one unattributed
 * "cannot load target"). */
static int gb_load_errno;

static int gb_fail(int e)
{
    gb_load_errno = e;
    return -1;
}

static void gb_die_path(const char *msg, const char *path)
{
    char digits[12];
    int nd = 0, e = gb_load_errno;
    write(2, "gbexec: ", 8);
    write(2, msg, strlen(msg));
    write(2, " ", 1);
    write(2, path, strlen(path));
    if (e > 0) {
        write(2, " (errno ", 8);
        while (e > 0) { digits[nd++] = (char) ('0' + e % 10); e /= 10; }
        while (nd > 0) write(2, &digits[--nd], 1);
        write(2, ")", 1);
    }
    write(2, "\n", 1);
    _exit(127);
}

struct gb_load_result {
    Elf32_Addr phdr;   /* runtime address of the target's phdrs */
    Elf32_Addr entry;  /* runtime entry point */
    Elf32_Addr bias;   /* load bias actually used */
    int phnum;
};

/* Map an ELF's PT_LOAD segments. For ET_EXEC the bias is 0 (segments
 * land on their link-time vaddrs); for ET_DYN the given bias is used.
 * Returns 0 on success. */
static int gb_load(const char *path, Elf32_Addr dyn_bias,
                   struct gb_load_result *res)
{
    static unsigned char phbuf[8192];
    Elf32_Ehdr eh;
    int fd, i;
    Elf32_Addr bias, minva = 0, phdr_addr = 0;

    fd = open(path, O_RDONLY);
    if (fd < 0) return gb_fail(errno);
    {
        ssize_t n = read(fd, &eh, sizeof(eh));
        if (n != (ssize_t) sizeof(eh)) {
            int e = (n < 0) ? errno : EIO;
            close(fd);
            return gb_fail(e);
        }
    }
    if (memcmp(eh.e_ident, ELFMAG, SELFMAG) != 0) { close(fd); return gb_fail(ENOEXEC); }
    if (eh.e_phnum == 0 || eh.e_phoff == 0 ||
        eh.e_phoff + eh.e_phnum * sizeof(Elf32_Phdr) > sizeof(phbuf)) {
        close(fd);
        return gb_fail(EINVAL);
    }
    if (lseek(fd, eh.e_phoff, SEEK_SET) < 0) { int e = errno; close(fd); return gb_fail(e); }
    {
        ssize_t n = read(fd, phbuf, eh.e_phnum * sizeof(Elf32_Phdr));
        if (n != (ssize_t) (eh.e_phnum * sizeof(Elf32_Phdr))) {
            int e = (n < 0) ? errno : EIO;
            close(fd);
            return gb_fail(e);
        }
    }

    bias = (eh.e_type == ET_DYN) ? dyn_bias : 0;

    for (i = 0; i < eh.e_phnum; i++) {
        Elf32_Phdr *ph = (Elf32_Phdr *) (phbuf + i * sizeof(Elf32_Phdr));
        Elf32_Addr va, off, fsz_end, msz_end;
        int prot = 0, mp;
        void *p;

        if (ph->p_type == PT_PHDR) phdr_addr = bias + ph->p_vaddr;
        if (ph->p_type != PT_LOAD) continue;

        va = bias + (ph->p_vaddr & ~0xfffu);
        off = ph->p_offset & ~0xfffu;
        if (minva == 0 || va < minva) minva = va;
        if (ph->p_flags & PF_R) prot |= PROT_READ;
        if (ph->p_flags & PF_W) prot |= PROT_WRITE;
        if (ph->p_flags & PF_X) prot |= PROT_EXEC;

        fsz_end = bias + ph->p_vaddr + ph->p_filesz;
        msz_end = bias + ph->p_vaddr + ph->p_memsz;
        /* File-backed part (rounded out to whole pages). A segment
         * with a zero page-rounded length (the GB linker ships a
         * PT_LOAD with filesz 0) must be skipped: mmap with length 0
         * fails EINVAL (gate run 42765297042, qemu strace). */
        {
            Elf32_Addr fsz_page_end = (fsz_end + 0xfffu) & ~0xfffu;
            if (fsz_page_end > va) {
                p = mmap((void *) va, fsz_page_end - va,
                         prot, MAP_PRIVATE | MAP_FIXED, fd, off);
                if (p == MAP_FAILED) { int e = errno; close(fd); return gb_fail(e); }
            }
            /* Zero the tail of the last file page beyond filesz,
             * then any whole anonymous pages up to memsz. */
            if (msz_end > fsz_end) {
                Elf32_Addr tail_end = fsz_page_end;
                if (tail_end > msz_end) tail_end = msz_end;
                if (tail_end > fsz_end)
                    memset((void *) fsz_end, 0, tail_end - fsz_end);
                if (msz_end > fsz_page_end) {
                    p = mmap((void *) fsz_page_end, msz_end - fsz_page_end,
                             prot, MAP_PRIVATE | MAP_FIXED | MAP_ANONYMOUS,
                             -1, 0);
                    if (p == MAP_FAILED) { int e = errno; close(fd); return gb_fail(e); }
                }
            }
        }
        (void) mp;
        /* The phdrs sit inside the first load segment that covers
         * e_phoff (used when there is no PT_PHDR). */
        if (phdr_addr == 0 &&
            eh.e_phoff >= ph->p_offset &&
            eh.e_phoff < ph->p_offset + ph->p_filesz)
            phdr_addr = bias + ph->p_vaddr + (eh.e_phoff - ph->p_offset);
    }
    close(fd);
    res->phdr = phdr_addr;
    res->entry = bias + eh.e_entry;
    res->bias = bias;
    res->phnum = eh.e_phnum;
    return 0;
}

int main(int argc, char **argv)
{
    struct gb_load_result target, linker;
    const char *target_path;
    char **targv;
    int targc, envc, i, auxc;
    static unsigned long auxbuf[128]; /* 64 auxv pairs */
    unsigned long *sp_top, *sp;
    char *stack_base;

    if (argc < 2) gb_die("no target");
    target_path = argv[1];
    if (argc >= 3) {
        targv = argv + 2;
        targc = argc - 2;
    } else {
        targv = argv + 1; /* just the target path as argv[0] */
        targc = 1;
    }

    if (gb_load(target_path, 0, &target) != 0)
        gb_die_path("cannot load target", target_path);
    if (gb_load("/system/bin/linker", GBEXEC_LINKER_BASE, &linker) != 0)
        gb_die_path("cannot load linker", "/system/bin/linker");

    /* Read our own auxv to clone the kernel-provided values. */
    auxc = 0;
    {
        int fd = open("/proc/self/auxv", O_RDONLY);
        if (fd >= 0) {
            ssize_t n = read(fd, auxbuf, sizeof(auxbuf) - 16);
            close(fd);
            if (n > 0) auxc = (int) (n / (2 * sizeof(unsigned long)));
        }
    }
    /* Patch or append the entries that describe the target. */
    {
        struct { unsigned long key, val; } fix[8];
        int nfix = 0, j;
        fix[nfix].key = AT_PHDR;   fix[nfix].val = target.phdr;   nfix++;
        fix[nfix].key = AT_PHNUM;  fix[nfix].val = target.phnum;  nfix++;
        /* AT_BASE: where the interpreter's image starts. The GB
         * linker is ET_EXEC linked at GBEXEC_LINKER_BASE (bias 0);
         * for an ET_DYN interpreter it is the bias we loaded at.
         * (The GB linker in fact ignores AT_BASE: its base is fixed
         * at link time.) */
        fix[nfix].key = AT_BASE;
        fix[nfix].val = linker.bias ? linker.bias : GBEXEC_LINKER_BASE;
        nfix++;
        fix[nfix].key = AT_ENTRY;  fix[nfix].val = target.entry;  nfix++;
        fix[nfix].key = AT_PAGESZ; fix[nfix].val = 4096;          nfix++;
        fix[nfix].key = AT_UID;    fix[nfix].val = getuid();      nfix++;
        fix[nfix].key = AT_EUID;   fix[nfix].val = geteuid();     nfix++;
        fix[nfix].key = AT_GID;    fix[nfix].val = getgid();      nfix++;
        fix[nfix].key = AT_EGID;   fix[nfix].val = getegid();     nfix++;
        for (j = 0; j < nfix; j++) {
            int found = 0;
            for (i = 0; i < auxc; i++) {
                if (auxbuf[2 * i] == fix[j].key) {
                    auxbuf[2 * i + 1] = fix[j].val;
                    found = 1;
                    break;
                }
            }
            if (!found && auxc < 62) {
                auxbuf[2 * auxc] = fix[j].key;
                auxbuf[2 * auxc + 1] = fix[j].val;
                auxc++;
            }
        }
    }

    for (envc = 0; environ[envc]; envc++) { }

    stack_base = mmap(0, GBEXEC_STACK_SIZE, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (stack_base == MAP_FAILED) gb_die("cannot mmap stack");
    sp_top = (unsigned long *) (((unsigned long) stack_base +
                                 GBEXEC_STACK_SIZE) & ~15u);
    /* Layout: [argc][argv...][NULL][envp...][NULL][auxv pairs][AT_NULL] */
    sp = sp_top - (1 + (targc + 1) + (envc + 1) + 2 * (auxc + 1));
    {
        unsigned long *p = sp;
        int j;
        *p++ = (unsigned long) targc;
        for (j = 0; j < targc; j++) *p++ = (unsigned long) targv[j];
        *p++ = 0;
        for (j = 0; j < envc; j++) *p++ = (unsigned long) environ[j];
        *p++ = 0;
        for (j = 0; j < auxc; j++) {
            *p++ = auxbuf[2 * j];
            *p++ = auxbuf[2 * j + 1];
        }
        *p++ = AT_NULL;
        *p++ = 0;
    }

    /* Enter the linker the way the kernel would: sp points at the
     * fabricated elfdata block, everything else is its problem now.
     * (The linker's begin.S does "mov r0, sp" itself.) */
    {
        register void *entry __asm__("r1") = (void *) linker.entry;
        register void *newsp __asm__("r0") = (void *) sp;
        __asm__ volatile (
            "mov sp, r0\n"
            "bx r1\n"
            : : "r" (newsp), "r" (entry) : "memory");
    }
    _exit(126); /* only reached if the linker entry returns */
    return 126;
}
