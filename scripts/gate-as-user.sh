#!/usr/bin/env bash
# Runs as user "builder" inside the era container, cwd mounted at /aosp.
#
# Gate pipeline (workline A pre-checks, DESIGN-M1.md):
#   Phase 1:  full build of the PATCHED tree (reuses probe 1's script).
#   Phase 1b: build the gate probe modules (gbexec, gate_smoke,
#             gate_helper, gate_helper_dyn) explicitly.
#   Phase 2:  disassembly spot-check of the produced libc.so: sample
#             syscall stubs must route through __gb_gate_pre/post.
#   Phase 3:  boot regression: the patched tree must still pass the
#             four emulator milestones with GBROOT unset (the gate is
#             transparent). Phases 3's code is boot-as-user.sh's
#             phases 2-5, unchanged except for this header.
#
# The build result gates the job; boot milestones are data (the
# summary files speak), exactly like the boot baseline.
cd /aosp || exit 1
export HOME=/home/builder
export LC_ALL=C
export JAVA_HOME="$(ls -d /usr/lib/jvm/java-6-openjdk* 2>/dev/null | head -1)"
export PATH="$JAVA_HOME/bin:$PATH"

LOGD=/report/bootlog
mkdir -p "$LOGD"
SUMMARY=/report/boot-summary.txt
: > "$SUMMARY"
say() { echo "$@" | tee -a "$SUMMARY"; }

# ---------------- Phase 1: patched full build ----------------
bash /scripts/build-as-user.sh
BUILD_RC=$?
say "phase1 build-as-user rc=$BUILD_RC"
if [ $BUILD_RC -ne 0 ]; then
  say "RESULT: BUILD FAILED - no further gate checks"
  exit $BUILD_RC
fi
PD="$(cat /report/product-dir.txt)"
say "product dir: $PD"

# ---------------- Phase 1b: probe modules ----------------
set -x
source build/envsetup.sh
for combo in generic-eng full-eng; do
  if lunch "$combo"; then break; fi
done
make gbexec gate_smoke gate_helper gate_helper_dyn \
  > /report/probes-build.log 2>&1
PROBES_RC=$?
set +x
echo "probes make rc=$PROBES_RC" > /report/probes-result.txt
tail -30 /report/probes-build.log >> /report/probes-result.txt
if [ $PROBES_RC -ne 0 ]; then
  say "RESULT: PROBE BUILD FAILED rc=$PROBES_RC"
  exit $PROBES_RC
fi
for m in gbexec gate_smoke gate_helper gate_helper_dyn; do
  ls -la "$PD/system/bin/$m" >> /report/probes-result.txt 2>&1
done

# ---------------- Phase 2: disassembly spot-check ----------------
OBJDUMP="$(find prebuilt -name 'arm-eabi-objdump' -type f 2>/dev/null | head -1)"
LIBC="$PD/system/lib/libc.so"
{
  echo "== objdump: $OBJDUMP =="
  echo "== libc: $LIBC =="
  ls -la "$LIBC"
  echo
  echo "== gate symbols present in libc.so =="
  "$OBJDUMP" -t "$LIBC" 2>/dev/null | grep -i "gb_gate" || echo "NONE FOUND"
  echo
  for sym in write getpid __open; do
    echo "===== stub: $sym ====="
    "$OBJDUMP" -d "$LIBC" 2>/dev/null | awk -v s="<$sym>:" '
      $0 ~ s {show=1} show {print} show && /^$/ {exit}'
    echo
  done
  echo "== gate-built linker / gbexec headers =="
  "$OBJDUMP" -f "$PD/system/bin/linker" 2>/dev/null | head -5
  "$OBJDUMP" -f "$PD/system/bin/gbexec" 2>/dev/null | head -5
  echo "== gbexec program headers (first LOAD vaddr must be 0x10000000) =="
  "$OBJDUMP" -p "$PD/system/bin/gbexec" 2>/dev/null | grep -A1 "LOAD" | head -8
} > /report/disasm.txt 2>&1
cat /report/disasm.txt
if grep -q "__gb_gate_pre" /report/disasm.txt; then
  say "disasm: stubs route through __gb_gate_pre (see disasm.txt)"
else
  say "disasm: WARNING - no __gb_gate_pre found in libc.so disassembly"
  echo "DISASM FAILED" > /report/FAILED-DISASM.txt
  exit 1
fi

# ---------------- Phase 3: boot regression (phases 2-5 of boot-as-user.sh) ----------------
# ---------------- Phase 2: boot inputs ----------------
EMU=/sdk/android-sdk-linux_x86/tools/emulator
{
  echo "== sdk =="
  cat /sdk/VERSION.txt 2>/dev/null
  ls -la "$EMU" 2>/dev/null
  echo "== images =="
  ls -la "$PD"/*.img 2>/dev/null
  echo "== kernels shipped in tree =="
  ls -la prebuilt/android-arm/kernel/ 2>/dev/null
  echo "== cpu abi of the built system =="
  grep -i "cpu.abi" "$PD/system/build.prop" 2>/dev/null
} > /report/boot-inputs.txt 2>&1
file "$EMU" > /report/boot-emulator-file.txt 2>&1
ldd "$EMU" > /report/boot-emulator-ldd.txt 2>&1 || true

ABI="$(grep -i 'ro.product.cpu.abi=' "$PD/system/build.prop" 2>/dev/null | head -1 | cut -d= -f2)"
if echo "$ABI" | grep -q "v7"; then
  KERNEL=prebuilt/android-arm/kernel/kernel-qemu-armv7
else
  KERNEL=prebuilt/android-arm/kernel/kernel-qemu
fi
say "cpu abi: ${ABI:-unknown}; kernel: $KERNEL"
ADB="$PWD/out/host/linux-x86/bin/adb"
say "emulator: $EMU"
say "adb: $ADB"

if [ ! -x "$EMU" ]; then
  say "RESULT: emulator binary missing/not executable - boot not attempted"
  exit 0
fi
if [ ! -f "$KERNEL" ]; then
  say "RESULT: kernel $KERNEL missing - boot not attempted"
  exit 0
fi

# ---------------- Phase 3: boot ----------------
export SDL_VIDEODRIVER=dummy
# Without an AVD the r12 emulator needs to be told where the system
# directory is (round 1 died on exactly this). The AOSP dev flow uses
# ANDROID_PRODUCT_OUT; -sysdir states the same location explicitly.
export ANDROID_PRODUCT_OUT="$PWD/$PD"
mkdir -p "$HOME/.android"
# Absolute image paths: with a sysdir set, the emulator resolves
# relative image paths against it (round 2 doubled the prefix and
# died on a nonexistent system.img).
"$EMU" -kernel "$PWD/$KERNEL" \
       -sysdir "$PWD/$PD" \
       -ramdisk "$PWD/$PD/ramdisk.img" \
       -system "$PWD/$PD/system.img" \
       -data "$PWD/$PD/userdata.img" \
       -memory 512 \
       -no-window -no-audio -verbose \
       > "$LOGD/emulator.log" 2>&1 &
EMU_PID=$!
say "emulator pid: $EMU_PID"

"$ADB" kill-server > /dev/null 2>&1
"$ADB" start-server > /dev/null 2>&1

# Continuous logcat capture from first device contact until teardown.
( "$ADB" wait-for-device > /dev/null 2>&1
  timeout 900 "$ADB" logcat -v time > "$LOGD/logcat.txt" 2>&1 ) &
LOGCAT_PID=$!

BOOT_TIMEOUT=600
START=$(date +%s)
{
  echo "# elapsed_s adb_state sys.boot_completed init.svc.servicemanager init.svc.zygote init.svc.bootanim"
  while :; do
    NOW=$(date +%s); EL=$((NOW - START))
    if [ $EL -gt $BOOT_TIMEOUT ]; then
      echo "# timeout after ${EL}s"
      break
    fi
    if ! kill -0 $EMU_PID 2>/dev/null; then
      echo "# emulator process died at ${EL}s"
      break
    fi
    STATE="$("$ADB" get-state 2>/dev/null)"
    BC=""; SM=""; ZY=""; BA=""
    if [ "$STATE" = "device" ]; then
      BC="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
      SM="$("$ADB" shell getprop init.svc.servicemanager 2>/dev/null | tr -d '\r')"
      ZY="$("$ADB" shell getprop init.svc.zygote 2>/dev/null | tr -d '\r')"
      BA="$("$ADB" shell getprop init.svc.bootanim 2>/dev/null | tr -d '\r')"
    fi
    echo "$EL ${STATE:-none} ${BC:-} ${SM:-} ${ZY:-} ${BA:-}"
    if [ "$BC" = "1" ]; then
      echo "# sys.boot_completed=1 at ${EL}s"
      break
    fi
    sleep 10
  done
} > /report/boot-timeline.txt 2>&1
cat /report/boot-timeline.txt

# Let logcat flush the tail before teardown.
sleep 10

# ---------------- Phase 4: final guest state ----------------
"$ADB" shell ps > "$LOGD/ps.txt" 2>&1 || true
"$ADB" shell getprop > "$LOGD/getprop.txt" 2>&1 || true
"$ADB" shell dmesg > "$LOGD/dmesg.txt" 2>&1 || true
"$ADB" shell service list > "$LOGD/services.txt" 2>&1 || true
"$ADB" shell cat /proc/cmdline > "$LOGD/cmdline.txt" 2>&1 || true
"$ADB" emu kill > /dev/null 2>&1 || true
kill $LOGCAT_PID > /dev/null 2>&1 || true
kill $EMU_PID > /dev/null 2>&1 || true
sleep 3
kill -9 $EMU_PID > /dev/null 2>&1 || true

# ---------------- Phase 5: milestone evaluation ----------------
MILE=/report/boot-milestones.txt
{
  echo "== M1: init started and executed init.rc =="
  if grep -q " /init" "$LOGD/ps.txt" 2>/dev/null \
     && grep -q "\[init\.svc\." "$LOGD/getprop.txt" 2>/dev/null; then
    echo "M1: YES"
  else
    echo "M1: NO"
  fi
  echo "-- evidence: ps /init line, init.svc.* properties, logcat init lines"
  grep " /init" "$LOGD/ps.txt" 2>/dev/null | head -2
  grep "\[init\.svc\." "$LOGD/getprop.txt" 2>/dev/null | head -5
  grep -i "init" "$LOGD/logcat.txt" 2>/dev/null | head -3

  echo
  echo "== M2: servicemanager and zygote running =="
  SMV="$(grep '\[init\.svc\.servicemanager\]' "$LOGD/getprop.txt" 2>/dev/null)"
  ZYV="$(grep '\[init\.svc\.zygote\]' "$LOGD/getprop.txt" 2>/dev/null)"
  if echo "$SMV" | grep -q "running" && echo "$ZYV" | grep -q "running"; then
    echo "M2: YES"
  else
    echo "M2: NO"
  fi
  echo "$SMV"
  echo "$ZYV"
  grep -i "servicemanager\|app_process\|zygote" "$LOGD/ps.txt" 2>/dev/null | head -4

  echo
  echo "== M3: system_server started =="
  if grep -q "system_server" "$LOGD/ps.txt" 2>/dev/null \
     || grep -qi "SystemServer" "$LOGD/logcat.txt" 2>/dev/null; then
    echo "M3: YES"
  else
    echo "M3: NO"
  fi
  grep "system_server" "$LOGD/ps.txt" 2>/dev/null | head -2
  grep -i "systemserver\|system_server" "$LOGD/logcat.txt" 2>/dev/null | head -3

  echo
  echo "== M4: sys.boot_completed=1 (bootanimation state recorded too) =="
  if grep -q "\[sys\.boot_completed\]: \[1\]" "$LOGD/getprop.txt" 2>/dev/null \
     || grep -q "boot_completed=1" /report/boot-timeline.txt 2>/dev/null \
     || grep -q "# sys.boot_completed=1" /report/boot-timeline.txt 2>/dev/null; then
    echo "M4: YES"
  else
    echo "M4: NO"
  fi
  grep "\[sys\.boot_completed\]" "$LOGD/getprop.txt" 2>/dev/null
  grep "\[init\.svc\.bootanim\]" "$LOGD/getprop.txt" 2>/dev/null

  echo
  echo "== last timeline rows =="
  tail -5 /report/boot-timeline.txt 2>/dev/null
  echo "== emulator log tail =="
  tail -20 "$LOGD/emulator.log" 2>/dev/null
  echo "== logcat tail =="
  tail -20 "$LOGD/logcat.txt" 2>/dev/null
} > "$MILE" 2>&1
cat "$MILE"

for m in M1 M2 M3 M4; do
  v="$(grep "^$m:" "$MILE" | head -1)"
  say "milestone $v"
done
say "RESULT: boot baseline pipeline finished (see boot-milestones.txt)"
exit 0
