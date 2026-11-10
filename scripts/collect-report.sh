#!/usr/bin/env bash
# Host side, always runs: assemble report/ from whatever the build left.
set -x
mkdir -p report

cp tree-revisions.txt report/ 2>/dev/null || true

PD=""
for d in aosp/out/target/product/*/; do
  [ -d "$d" ] && PD="$d"
done

if [ -n "$PD" ] && [ -d "${PD}system" ]; then
  SYS="${PD}system"
  {
    echo "product dir: $PD"
    echo "system file count: $(find "$SYS" -type f | wc -l)"
    echo "system total size: $(du -sh "$SYS" | cut -f1)"
    echo
    echo "== key binaries =="
    check() {
      p="$1"
      if [ -e "$p" ]; then
        printf 'YES  %-55s %10s bytes  %s\n' "$p" "$(stat -c%s "$p")" "$(file -b "$p" | cut -c1-60)"
      else
        printf 'NO   %-55s missing\n' "$p"
      fi
    }
    check "${PD}root/init"
    check "${PD}system/bin/app_process"
    check "${PD}system/bin/dalvikvm"
    check "${PD}system/bin/servicemanager"
    check "${PD}system/lib/libbinder.so"
    check "${PD}system/lib/libandroid_runtime.so"
    check "${PD}system/lib/libandroid_servers.so"
    check "${PD}system/framework/services.jar"
    check "${PD}system/framework/framework.jar"
    check "${PD}system.img"
  } > report/key-binaries.txt 2>&1

  (cd "$SYS" && find . -type f -printf '%10s  %p\n' | sort -k2) \
    > report/system-tree.txt 2>&1
fi

# Keep the full build log's tail in the report even on success.
tail -200 aosp/out-build.log > report/build-log-tail.txt 2>/dev/null || true

ls -la report/
cat report/key-binaries.txt 2>/dev/null || echo "no system tree produced"
