# Gate probes for the M1 compat layer (workline A). Copied into the
# AOSP tree at external/gate_probes by scripts/apply-patches.sh; the
# modules are built explicitly by the gate workflow after the full
# make, and gbexec + gate_smoke are packed into the rootfs artifact.
LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := gbexec
LOCAL_SRC_FILES := gbexec.c
LOCAL_FORCE_STATIC_EXECUTABLE := true
LOCAL_STATIC_LIBRARIES := libc
# gbexec must not collide with the guest executable it loads (0x8000),
# the mmap area, the guest linker (0xB0000000) or the stack; park it
# at 0x10000000 (same -Ttext mechanism the linker itself uses).
LOCAL_LDFLAGS := -Wl,-Ttext=0x10000000
LOCAL_MODULE_TAGS := optional
include $(BUILD_EXECUTABLE)

include $(CLEAR_VARS)
LOCAL_MODULE := gate_smoke
LOCAL_SRC_FILES := gate_smoke.c
LOCAL_FORCE_STATIC_EXECUTABLE := true
LOCAL_STATIC_LIBRARIES := libc
LOCAL_MODULE_TAGS := optional
include $(BUILD_EXECUTABLE)

include $(CLEAR_VARS)
LOCAL_MODULE := gate_helper
LOCAL_SRC_FILES := gate_helper.c
LOCAL_FORCE_STATIC_EXECUTABLE := true
LOCAL_STATIC_LIBRARIES := libc
LOCAL_MODULE_TAGS := optional
include $(BUILD_EXECUTABLE)

include $(CLEAR_VARS)
LOCAL_MODULE := gate_helper_dyn
LOCAL_SRC_FILES := gate_helper_dyn.c
LOCAL_MODULE_TAGS := optional
include $(BUILD_EXECUTABLE)
