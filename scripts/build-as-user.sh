#!/usr/bin/env bash
# Runs as user "builder" inside the era container, cwd mounted at /aosp.
# Builds the whole tree and writes the evidence report into /report.
cd /aosp || exit 1
export HOME=/home/builder
export LC_ALL=C
export JAVA_HOME="$(ls -d /usr/lib/jvm/java-6-openjdk* 2>/dev/null | head -1)"
export PATH="$JAVA_HOME/bin:$PATH"

set -x
source build/envsetup.sh

# Prefer the generic ARM product; fall back to full-eng if this tree
# does not offer generic-eng. Record whichever combo actually took.
LUNCH_USED=""
for combo in generic-eng full-eng; do
  if lunch "$combo"; then
    if [ -n "$(get_build_var TARGET_PRODUCT)" ]; then
      LUNCH_USED="$combo"
      break
    fi
  fi
done

{
  echo "lunch combo: ${LUNCH_USED:-NONE}"
  echo "TARGET_PRODUCT=$(get_build_var TARGET_PRODUCT)"
  echo "TARGET_BUILD_VARIANT=$(get_build_var TARGET_BUILD_VARIANT)"
  echo "TARGET_ARCH=$(get_build_var TARGET_ARCH)"
  echo "TARGET_ARCH_VARIANT=$(get_build_var TARGET_ARCH_VARIANT)"
} > /report/lunch.txt 2>&1
cat /report/lunch.txt

if [ -z "$LUNCH_USED" ]; then
  echo "FATAL: no lunch combo succeeded" > /report/FAILED.txt
  exit 1
fi

PRODUCT_DIR="out/target/product/$(get_build_var TARGET_PRODUCT)"
echo "$PRODUCT_DIR" > /report/product-dir.txt

START=$(date +%s)
make -j"$(nproc)" > /aosp/out-build.log 2>&1
MAKE_RC=$?
END=$(date +%s)
echo "make rc=$MAKE_RC elapsed=$((END - START))s" > /report/make-result.txt
tail -50 /aosp/out-build.log > /report/build-log-tail.txt || true

if [ $MAKE_RC -ne 0 ]; then
  echo "make failed rc=$MAKE_RC" > /report/FAILED.txt
  exit $MAKE_RC
fi
exit 0
