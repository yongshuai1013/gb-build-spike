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
echo "SMOKE OK"
