#!/usr/bin/env bash
# Host side, always runs: fold the host-produced evidence (smoke,
# rootfs listing, patch state) into gate-report/ alongside the files
# the container already wrote there, and write the summary index.
set -x
mkdir -p gate-report

cp tree-revisions.txt gate-report/ 2>/dev/null || true
cp patch-state.txt gate-report/ 2>/dev/null || true
cp rootfs-listing.txt gate-report/ 2>/dev/null || true
cp rootfs-sha256.txt gate-report/ 2>/dev/null || true
cp smoke-stdout.txt gate-report/ 2>/dev/null || true
cp smoke-strace.txt gate-report/ 2>/dev/null || true
cp smoke-host-checks.txt gate-report/ 2>/dev/null || true
cp init-stdout.txt gate-report/ 2>/dev/null || true
cp init-stderr.txt gate-report/ 2>/dev/null || true
cp init-strace.txt gate-report/ 2>/dev/null || true
cp init-host-checks.txt gate-report/ 2>/dev/null || true
cp init-blocked.txt gate-report/ 2>/dev/null || true
cp rootfs-init-test/dev/console gate-report/init-console.txt 2>/dev/null || true
cp patches/README.md gate-report/patch-manifest.md 2>/dev/null || true

{
  echo "gb gate-build report"
  echo "run: ${GITHUB_RUN_ID:-local}  sha: ${GITHUB_SHA:-local}"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "== files =="
  ls -la gate-report/
  echo
  echo "== make result =="
  cat gate-report/make-result.txt 2>/dev/null || echo "n/a"
  echo "== probes result =="
  cat gate-report/probes-result.txt 2>/dev/null || echo "n/a"
  echo "== boot milestones (patched tree, gate off) =="
  grep -E "^M[0-9]:" gate-report/boot-milestones.txt 2>/dev/null || echo "n/a"
  echo "== smoke (gate on, qemu-user) =="
  cat gate-report/smoke-stdout.txt 2>/dev/null || echo "n/a"
  cat gate-report/smoke-host-checks.txt 2>/dev/null || echo "n/a"
  echo "== guest init (gate on, qemu-user, 60s window) =="
  cat gate-report/init-host-checks.txt 2>/dev/null || echo "n/a"
} > gate-report/SUMMARY.txt 2>&1

cat gate-report/SUMMARY.txt
ls -la gate-report/
