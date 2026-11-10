#!/usr/bin/env bash
# Runs as user "builder" inside the era container, cwd mounted at /aosp.
#
# Boot baseline pipeline:
#   Phase 1: build the UNMODIFIED tree, reusing probe 1's script as-is.
#   Phase 2: assemble boot inputs: SDK r12 emulator (mounted at /sdk),
#            the tree's own prebuilt goldfish kernel, the images the
#            build just produced. Kernel variant follows the product's
#            ro.product.cpu.abi (v7 -> kernel-qemu-armv7).
#   Phase 3: boot headless, poll milestones over adb for up to 600 s.
#   Phase 4: collect final guest state (ps/getprop/dmesg/services).
#   Phase 5: evaluate the four milestones with evidence excerpts.
#
# Milestone shortfalls are data, not job failures: after a successful
# build this script exits 0 and lets boot-milestones.txt speak.
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

# ---------------- Phase 1: unmodified full build ----------------
bash /scripts/build-as-user.sh
BUILD_RC=$?
say "phase1 build-as-user rc=$BUILD_RC"
if [ $BUILD_RC -ne 0 ]; then
  say "RESULT: BUILD FAILED - no boot attempted"
  exit $BUILD_RC
fi
PD="$(cat /report/product-dir.txt)"
say "product dir: $PD"

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
"$EMU" -kernel "$KERNEL" \
       -sysdir "$PWD/$PD" \
       -ramdisk "$PD/ramdisk.img" \
       -system "$PD/system.img" \
       -data "$PD/userdata.img" \
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
