#!/usr/bin/env bash
# Inside Ubuntu 12.04 (precise): install the KitKat-era build
# environment, then drop privileges to a user matching the host UID.
#
# This is the Gingerbread probe's container recipe (gb-build-spike
# scripts/in-container.sh) reused nearly verbatim — 12.04 is the
# documented build platform for both GB and KitKat (OpenJDK 6,
# GNU make 3.81, gcc 4.6). Two deliberate differences:
#  1. No host compiler shims on round 1: the GB tree needed
#     -fpermissive/-Wno-error wrappers because it predates 12.04;
#     the KitKat tree was written against this exact platform.
#     If the host build proves otherwise, that becomes a fix round.
#  2. The build step runs kitkat/build-as-user.sh (module targets),
#     not the GB full-tree build.
set -x

# Precise is EOL: its packages live on old-releases.ubuntu.com now.
sed -i -e 's|archive.ubuntu.com|old-releases.ubuntu.com|g' \
       -e 's|security.ubuntu.com|old-releases.ubuntu.com|g' \
       /etc/apt/sources.list

dpkg --add-architecture i386 2>/dev/null || true
apt-get update

install_group() {
  echo "=== apt group: $* ==="
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  echo "=== group rc=$? ==="
}

# Group 1 (mandatory): host toolchain and build utilities, amd64 only.
install_group \
  git-core gnupg flex bison gperf build-essential zip curl unzip file \
  libc6-dev zlib1g-dev \
  libxml2-utils xsltproc tofrodos python-markdown perl python bc patch \
  openjdk-6-jdk
G1_RC=$?

# Group 2 (mandatory): 32-bit runtime libraries for the prebuilt
# toolchains (libc6-i386 ships /lib/ld-linux.so.2), plus the 32-bit
# development headers the -m32 host tools need.
install_group lib32z1 lib32ncurses5 lib32stdc++6 libc6-i386 libc6-dev-i386
G2_RC=$?

# Group 3 (best-effort): 32-bit development packages and multilib,
# historically listed for emulator/OpenGL host pieces. The target
# modules may not need them; failure here must not block the build.
install_group \
  libncurses5-dev:i386 libx11-dev:i386 libreadline6-dev:i386 \
  zlib1g-dev:i386 libgl1-mesa-glx:i386 libgl1-mesa-dev \
  x11proto-core-dev g++-multilib
G3_RC=$?
echo "apt groups: g1=$G1_RC g2=$G2_RC g3=$G3_RC" > /report/apt-groups.txt

# Era quirk from the official 12.04 instructions: some host tools link
# -lGL and only the versioned i386 libGL is present.
ln -sf /usr/lib/i386-linux-gnu/mesa/libGL.so.1 \
       /usr/lib/i386-linux-gnu/libGL.so 2>/dev/null || true

{
  echo "== container environment =="
  cat /etc/lsb-release 2>/dev/null
  java -version 2>&1 | head -3
  javac -version 2>&1
  make --version | head -1
  gcc --version | head -1
  python --version 2>&1
  ld --version | head -1
  ls -l /lib/ld-linux.so.2 /lib/i386-linux-gnu/ld-linux.so.2 2>/dev/null \
    || echo "no 32-bit loader found"
} > /report/environment.txt 2>&1
cat /report/environment.txt

if [ $G1_RC -ne 0 ] || [ $G2_RC -ne 0 ]; then
  echo "mandatory apt group failed (g1=$G1_RC g2=$G2_RC)" > /report/FAILED.txt
  exit 1
fi

# Build as a non-root user whose uid/gid match the host checkout owner.
groupadd -g "${HOST_GID:-1001}" builder 2>/dev/null || true
useradd -m -u "${HOST_UID:-1001}" -g "${HOST_GID:-1001}" builder 2>/dev/null || true

cp /scripts/build-as-user.sh /tmp/build-as-user.sh
chmod +x /tmp/build-as-user.sh
su builder -c /tmp/build-as-user.sh
BUILD_RC=$?
echo "in-container build rc=$BUILD_RC"
exit $BUILD_RC
