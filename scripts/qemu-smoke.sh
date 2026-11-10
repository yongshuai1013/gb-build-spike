#!/usr/bin/env bash
# Host side: run the guest smoke test (gate_smoke, statically linked
# against the gate-patched libc) under qemu-user with the gate ON,
# using the assembled rootfs as GBROOT, then verify the host-side
# evidence (files must have landed inside the rootfs).
#
# QEMU_STRACE is enabled: qemu-user's own guest-execve re-execution is
# unreliable in several qemu builds (a plain glibc reproducer gets
# ENOEXEC), so the execve *translation* is graded from the trace
# (the stub must issue execve() with the rootfs-prefixed path), while
# the in-guest exec results are reported by the probe as evidence.
set -x

ROOTFS="$PWD/rootfs"
SMK="$ROOTFS/system/bin/gate_smoke"
if [ ! -x "$SMK" ]; then
  echo "FATAL: $SMK missing - run scripts/assemble-rootfs.sh first"
  exit 1
fi
if ! command -v qemu-arm-static >/dev/null; then
  echo "FATAL: qemu-arm-static not installed"
  exit 1
fi

rm -f "$ROOTFS/data/gate-smoke.txt" \
      "$ROOTFS/data/gate-helper.txt" \
      "$ROOTFS/data/gate-helper-dyn.txt"
: > "$ROOTFS/dev/console"

GBROOT="$ROOTFS" GBVPID=4242 GBGATE=1 QEMU_STRACE=1 \
  timeout 180 qemu-arm-static "$SMK" \
  > smoke-stdout.txt 2> smoke-strace.txt
SMOKE_RC=$?
echo "gate_smoke exit code: $SMOKE_RC (core-check failures)"
cat smoke-stdout.txt

{
  echo "== host-side evidence =="
  ok=1
  check_file() {
    f="$1"; want="$2"
    if [ -f "$f" ] && grep -q "$want" "$f"; then
      echo "YES  $f ($(stat -c%s "$f") bytes) contains '$want'"
    else
      echo "NO   $f missing or lacks '$want'"
      ok=0
    fi
  }
  check_file "$ROOTFS/data/gate-smoke.txt" "gate-smoke-data"
  check_file "$ROOTFS/dev/console" "gate-smoke-console"
  echo
  echo "== exec evidence (probe-reported, qemu-dependent) =="
  grep "SMOKE exec" smoke-stdout.txt || echo "no exec lines"
  echo
  echo "== execve translation evidence (qemu strace) =="
  grep -E "execve\(" smoke-strace.txt | head -5 || echo "no execve traced"
  if grep -q "execve(\"$ROOTFS/system/bin/gate_helper\"" smoke-strace.txt; then
    echo "TRANSLATED execve to rootfs gate_helper: YES"
  else
    echo "TRANSLATED execve to rootfs gate_helper: NO"
  fi
  if grep -q "execve(\"$ROOTFS/system/bin/gbexec\"" smoke-strace.txt; then
    echo "TRANSLATED execve to rootfs gbexec (dynamic): YES"
  else
    echo "TRANSLATED execve to rootfs gbexec (dynamic): NO"
  fi
  echo
  echo "host checks ok=$ok smoke_rc=$SMOKE_RC"
} > smoke-host-checks.txt 2>&1
cat smoke-host-checks.txt


# ---- Phase 2: guest init liveness + seccomp shield trace ----
# Run the real guest init (static, gate ON) under qemu-user with
# strace for a bounded window. qemu has no Android app seccomp
# filter, so the shield is graded from the trace: the guest must
# never ISSUE a syscall the host app policy denies - on a real
# device issuing one is what killed the M1 guest init 3ms into its
# first run (rc=159 = 128+SIGSYS, at its first mount()). Also
# graded: init is still alive when the window ends (its main loop
# never returns), and its boot log reached dev/console (log_init's
# /dev/__kmsg__ is redirected there by the gate). Runs against a
# copy: init creates device files and directories inside GBROOT,
# and the assembled rootfs/ tree must stay pristine.
GB2="$PWD/rootfs-init-test"
rm -rf "$GB2"
cp -a "$ROOTFS" "$GB2"
: > "$GB2/dev/console"
OUT="$PWD"
(
  cd "$GB2"
  GBROOT="$GB2" GBVPID=1 GBGATE=1 QEMU_STRACE=1 \
    timeout 60 qemu-arm-static ./init \
    > "$OUT/init-stdout.txt" 2> "$OUT/init-strace.txt"
  echo $? > "$OUT/init-rc.txt"
)
INIT_RC=$(cat init-rc.txt)
{
  ok2=1
  echo "== guest init window =="
  echo "init exit code after 60s window: $INIT_RC (124 = still alive, killed by timeout)"
  [ "$INIT_RC" = "124" ] || ok2=0
  echo "== guest boot log (dev/console) =="
  if grep -q "reading config file" "$GB2/dev/console"; then
    echo "YES  console contains init's 'reading config file'"
  else
    echo "NO   console lacks init's boot log line"
    ok2=0
  fi
  echo "== seccomp shield: blocked syscalls issued by the guest =="
  BLOCKED_RE='(^|[^a-zA-Z0-9_])(mount|umount|umount2|reboot|mknod|chmod|chown32|lchown32|chown|lchown|rmdir|symlink|link|accept|ftruncate|settimeofday|sethostname|setdomainname|setuid32|setgid32|setreuid32|setregid32|setresgid32|setgroups32|setuid|setgid|setgroups|pause|sigsuspend|sigprocmask|sigpending|ioprio_set|ioprio_get)\('
  if grep -E "$BLOCKED_RE" init-strace.txt > init-blocked.txt; then
    echo "NO   blocked syscalls were issued (first 10):"
    head -10 init-blocked.txt
    ok2=0
  else
    echo "YES  no blocked syscall issued in the window"
  fi
  echo "== shield rewrites observed (informational) =="
  echo "fchmodat calls: $(grep -cE 'fchmodat\(' init-strace.txt)"
  echo "fchownat calls: $(grep -cE 'fchownat\(' init-strace.txt)"
  echo "rt_sigsuspend calls: $(grep -cE 'rt_sigsuspend\(' init-strace.txt)"
  echo
  echo "init checks ok=$ok2 init_rc=$INIT_RC"
} > init-host-checks.txt 2>&1
cat init-host-checks.txt

# The job fails when the probe's core checks failed or the host-side
# file evidence is missing.
if [ $SMOKE_RC -ne 0 ]; then
  echo "SMOKE FAILED: gate_smoke core checks rc=$SMOKE_RC"
  exit 1
fi
grep -q "host checks ok=1" smoke-host-checks.txt || {
  echo "SMOKE FAILED: host-side evidence missing"
  exit 1
}
grep -q "init checks ok=1" init-host-checks.txt || {
  echo "SMOKE FAILED: guest init liveness/seccomp checks"
  exit 1
}
echo "SMOKE OK"
