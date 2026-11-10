#!/usr/bin/env bash
# Host side: assemble the guest rootfs from the gate build output per
# DESIGN-M1.md: the product's ramdisk root/ as the base, system/
# overlaid, plus empty data/ and the dev/ skeleton the compat layer
# expects to find as plain files/directories.
set -e -x

PD=""
for d in aosp/out/target/product/*/; do
  [ -d "$d" ] && PD="$d"
done
if [ -z "$PD" ] || [ ! -d "${PD}system" ]; then
  echo "FATAL: no product output found under aosp/out/target/product/"
  exit 1
fi
echo "product dir: $PD"

rm -rf rootfs rootfs.tar.gz rootfs-listing.txt
mkdir -p rootfs

# Base: ramdisk contents (init, init.rc, ueventd*.rc, default.prop...).
cp -a "${PD}root/." rootfs/
# Overlay: the system tree. NOTE: the ramdisk root already contains
# an (empty) system/ mount-point directory, so copy the *contents*
# over it - "cp -a ${PD}system rootfs/system" would nest the tree at
# rootfs/system/system/ (gate run 42761838414 died exactly there).
mkdir -p rootfs/system
cp -a "${PD}system/." rootfs/system/

# Skeleton the guest (and the app launcher) rely on.
mkdir -p rootfs/data rootfs/dev/log rootfs/dev/socket
: > rootfs/dev/console
for n in main radio events system; do
  : > "rootfs/dev/log/$n"
done

# The gate binaries must be inside: gbexec is load-bearing (the
# compat execve rewrite points at /system/bin/gbexec), gate_smoke is
# the on-device smoke binary.
for m in gbexec gate_smoke gate_helper gate_helper_dyn; do
  if [ ! -f "rootfs/system/bin/$m" ]; then
    echo "FATAL: rootfs/system/bin/$m missing (probe build failed?)"
    exit 1
  fi
done

{
  echo "rootfs assembled from $PD at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "file count: $(find rootfs -type f | wc -l)"
  echo "total size: $(du -sh rootfs | cut -f1)"
  echo
  (cd rootfs && find . -type f -printf '%10s  %p\n' | sort -k2)
} > rootfs-listing.txt

tar -czf rootfs.tar.gz -C rootfs .
sha256sum rootfs.tar.gz | tee rootfs-sha256.txt
ls -la rootfs.tar.gz
