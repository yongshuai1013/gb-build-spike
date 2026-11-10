#!/usr/bin/env bash
# Sync the AOSP android-2.3.7_r1 tree on the (modern) host.
# The era container only builds; it never talks to the network for source.
set -e -x

git config --global user.email "gb-build-spike@localhost"
git config --global user.name "gb-build-spike"

mkdir -p aosp
cd aosp

if [ ! -d .repo ]; then
  repo init -u https://android.googlesource.com/platform/manifest \
            -b android-2.3.7_r1
fi

# -c: only the manifest branch per project (keeps the tree/cache smaller).
repo sync -c -j"$(nproc)" --no-tags

# Record the checkouts that matter for cross-checking against the pinned
# revisions used by the GingerVM probes (bionic 3f14ff34..., system/core
# 838a24ac... are the android-2.3.7_r1 tag tips).
{
  echo "manifest branch: android-2.3.7_r1"
  for p in bionic system/core build dalvik frameworks/base; do
    echo "$p $(git -C "$p" rev-parse HEAD 2>/dev/null || echo MISSING)"
  done
} > ../tree-revisions.txt

du -sh .
df -h . | tail -1
