#!/usr/bin/env bash
# Runs as user "builder" inside the era container, tree mounted at /aosp.
# Builds ONLY the target module set (top-level make goals, so module
# dependencies are pulled automatically) and verifies each produced
# binary as an ARM ELF. A make failure does not abort verification:
# the per-module table is the probe's primary output either way.
cd /aosp || exit 1
export HOME=/home/builder
export LC_ALL=C
export JAVA_HOME="$(ls -d /usr/lib/jvm/java-6-openjdk* 2>/dev/null | head -1)"
export PATH="$JAVA_HOME/bin:$PATH"

MODULES="libc linker init servicemanager libcutils libutils libbinder"

set -x
source build/envsetup.sh

if lunch aosp_arm-eng; then
  LUNCH_USED="aosp_arm-eng"
fi

{
  echo "lunch combo: ${LUNCH_USED:-NONE}"
  echo "TARGET_PRODUCT=$(get_build_var TARGET_PRODUCT)"
  echo "TARGET_BUILD_VARIANT=$(get_build_var TARGET_BUILD_VARIANT)"
  echo "TARGET_ARCH=$(get_build_var TARGET_ARCH)"
  echo "TARGET_ARCH_VARIANT=$(get_build_var TARGET_ARCH_VARIANT)"
  echo "TARGET_DEVICE=$(get_build_var TARGET_DEVICE)"
} > /report/lunch.txt 2>&1
cat /report/lunch.txt

if [ -z "$LUNCH_USED" ]; then
  echo "FATAL: lunch aosp_arm-eng failed" > /report/FAILED.txt
  exit 1
fi

START=$(date +%s)
make -j"$(nproc)" $MODULES > /aosp/out-build.log 2>&1
MAKE_RC=$?
END=$(date +%s)
echo "make rc=$MAKE_RC elapsed=$((END - START))s targets: $MODULES" \
  > /report/make-result.txt
tail -80 /aosp/out-build.log > /report/build-log-tail.txt || true
df -h . | tail -1 > /report/disk-after-build.txt
du -sh out 2>/dev/null | cut -f1 > /report/out-size.txt

# ---- Per-module verification: installed image copies first, then the
# linked intermediates. Each hit is checked with file + readelf -h and
# copied into /report/bin/ as evidence.
mkdir -p /report/bin
: > /report/verify.txt
ALL_OK=1

check_one() {
  # $1 = module label, $2 = basename, rest = preferred glob patterns
  local label="$1" base="$2"; shift 2
  local found=""
  local pat f
  for pat in "$@"; do
    for f in $(compgen -G "$pat" 2>/dev/null); do
      [ -f "$f" ] && { found="$f"; break 2; }
    done
  done
  if [ -z "$found" ]; then
    found=$(find out/target/product -name "$base" -type f 2>/dev/null | head -1)
  fi
  if [ -z "$found" ]; then
    echo "$label MISSING (no $base under out/)" >> /report/verify.txt
    ALL_OK=0
    return
  fi
  local fdesc rhead
  fdesc=$(file "$found")
  rhead=$(readelf -h "$found" 2>/dev/null | grep -E 'Class:|Machine:' | tr '\n' ' ')
  echo "$label OK $found" >> /report/verify.txt
  echo "  file: $fdesc" >> /report/verify.txt
  echo "  readelf: $rhead" >> /report/verify.txt
  case "$rhead" in
    *ARM*) : ;;
    *) echo "  WARNING: not an ARM ELF" >> /report/verify.txt; ALL_OK=0 ;;
  esac
  cp "$found" "/report/bin/$base" 2>/dev/null || true
}

P="out/target/product/*"
check_one libc          libc.so          "$P/system/lib/libc.so"
check_one linker        linker           "$P/system/bin/linker"
check_one init          init             "$P/root/init" "$P/system/bin/init"
check_one servicemanager servicemanager  "$P/system/bin/servicemanager"
check_one libcutils     libcutils.so     "$P/system/lib/libcutils.so"
check_one libutils      libutils.so      "$P/system/lib/libutils.so"
check_one libbinder     libbinder.so     "$P/system/lib/libbinder.so"

cat /report/verify.txt
if [ $ALL_OK -eq 1 ]; then
  echo "verify: ALL MODULES OK" > /report/verdict.txt
else
  echo "verify: SOME MODULES MISSING" > /report/verdict.txt
fi
exit 0
