#!/usr/bin/env bash
# Host side: reset the gate-touched AOSP projects to stock and apply
# the patches in patches/ (idempotent), then copy the gate probes
# into the tree as external/gate_probes. Run from the repo root after
# scripts/sync-tree.sh. See patches/README.md for the patch manifest.
set -e -x

AOSP="${AOSP:-aosp}"
PATCHES="$PWD/patches"

# Reset to stock first: re-running this script (or re-running the
# workflow on a warm cache) must reproduce the same patched tree.
git -C "$AOSP/bionic" checkout -- .
git -C "$AOSP/bionic" clean -f -- libc/arch-arm/bionic/gb_gate.c
git -C "$AOSP/system/core" checkout -- .

for p in "$PATCHES"/bionic/*.patch; do
  git -C "$AOSP/bionic" apply --whitespace=nowarn "$p"
done
for p in "$PATCHES"/system-core/*.patch; do
  git -C "$AOSP/system/core" apply --whitespace=nowarn "$p"
done

rm -rf "$AOSP/external/gate_probes"
mkdir -p "$AOSP/external/gate_probes"
cp probes/*.c probes/Android.mk "$AOSP/external/gate_probes/"

# Spot-check the markers the rest of the pipeline relies on.
grep -q "__gb_gate_pre" "$AOSP/bionic/libc/arch-arm/syscalls/write.S"
grep -q "gb_gate.c" "$AOSP/bionic/libc/Android.mk"
test -f "$AOSP/bionic/libc/arch-arm/bionic/gb_gate.c"
grep -q "no uevent socket" "$AOSP/system/core/init/ueventd.c"
test -f "$AOSP/external/gate_probes/gbexec.c"

{
  echo "patched projects:"
  echo "bionic $(git -C "$AOSP/bionic" rev-parse HEAD)"
  echo "system/core $(git -C "$AOSP/system/core" rev-parse HEAD)"
  echo "bionic dirty files: $(git -C "$AOSP/bionic" status --porcelain | wc -l)"
  echo "system/core dirty files: $(git -C "$AOSP/system/core" status --porcelain | wc -l)"
} | tee patch-state.txt

echo "apply-patches: OK"
