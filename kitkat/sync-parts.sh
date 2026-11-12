#!/usr/bin/env bash
# Partial sync of android-4.4.4_r2 on the (modern) host: shallow clone,
# minimal project set only (see kitkat/README.md for the justification
# of every project). The era container only builds; it never talks to
# the network for source.
set -x

git config --global user.email "kitkat-parts-spike@localhost"
git config --global user.name "kitkat-parts-spike"

mkdir -p report aosp
cd aosp

PROJECTS="build bionic system/core frameworks/native system/extras \
external/libselinux \
external/compiler-rt \
prebuilts/clang/linux-x86/host/3.3 \
prebuilts/sdk \
prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.7 \
prebuilts/gcc/linux-x86/arm/arm-eabi-4.7"

if [ ! -d .repo ]; then
  repo init --depth=1 \
            -u https://android.googlesource.com/platform/manifest \
            -b android-4.4.4_r2
fi

START=$(date +%s)
# -c: only the manifest branch per project; named projects only.
repo sync -c -j"$(nproc)" --no-tags $PROJECTS
RC=$?
END=$(date +%s)
echo "repo sync rc=$RC elapsed=$((END - START))s" | tee ../report/sync-result.txt
if [ $RC -ne 0 ]; then
  echo "repo sync failed rc=$RC" > ../report/FAILED.txt
  exit $RC
fi

{
  echo "manifest branch: android-4.4.4_r2"
  for p in $PROJECTS; do
    printf '%s %s %s\n' "$p" \
      "$(git -C "$p" rev-parse HEAD 2>/dev/null || echo MISSING)" \
      "$(du -sh "$p" 2>/dev/null | cut -f1)"
  done
  echo "total: $(du -sh . | cut -f1)"
} | tee ../report/sync-projects.txt

df -h . | tail -1 | tee ../report/disk-after-sync.txt
