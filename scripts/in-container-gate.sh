#!/usr/bin/env bash
# Inside Ubuntu 12.04 (precise): same era build environment as probe 1
# (see in-container.sh for the rationale), plus the 32-bit runtime
# libraries the SDK r12 emulator binary needs, then drop privileges to
# a user matching the host UID and run the build+gate pipeline.
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
# toolchains, plus the 32-bit development headers Gingerbread's -m32
# host tools need (see in-container.sh / README of probe 1).
install_group lib32z1 lib32ncurses5 lib32stdc++6 libc6-i386 libc6-dev-i386
G2_RC=$?

# Group 3 (best-effort): 32-bit development packages and multilib.
install_group \
  libncurses5-dev:i386 libx11-dev:i386 libreadline6-dev:i386 \
  zlib1g-dev:i386 libgl1-mesa-glx:i386 libgl1-mesa-dev \
  x11proto-core-dev g++-multilib
G3_RC=$?
echo "apt groups: g1=$G1_RC g2=$G2_RC g3=$G3_RC" > /report/apt-groups.txt

# Group 4 (boot-only, per-package best-effort): 32-bit *runtime*
# libraries for the SDK r12 emulator (an i386 binary using SDL + X11).
# Installed one by one so one missing name cannot sink the rest; the
# ldd dump in the report shows whatever is still missing afterwards.
{
  echo "== emulator runtime libs (i386) =="
  for pkg in libsdl1.2debian:i386 libx11-6:i386 libxext6:i386 \
             libxau6:i386 libxcb1:i386 libxdmcp6:i386 libxrender1:i386; do
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
    echo "pkg $pkg rc=$?"
  done
} > /report/apt-emu-libs.txt 2>&1

# Era quirk from the official 12.04 instructions: some host tools link
# -lGL and only the versioned i386 libGL is present.
ln -sf /usr/lib/i386-linux-gnu/mesa/libGL.so.1 \
       /usr/lib/i386-linux-gnu/libGL.so 2>/dev/null || true

# Host-compiler shims (identical to probe 1; see in-container.sh).
cat > /usr/local/bin/g++ <<'EOF'
#!/bin/sh
exec /usr/bin/g++ "$@" -fpermissive -Wno-error
EOF
cat > /usr/local/bin/gcc <<'EOF'
#!/bin/sh
exec /usr/bin/gcc "$@" -Wno-error
EOF
chmod +x /usr/local/bin/g++ /usr/local/bin/gcc

{
  echo "== container environment =="
  cat /etc/lsb-release 2>/dev/null
  java -version 2>&1 | head -3
  make --version | head -1
  gcc --version | head -1
  python --version 2>&1
} > /report/environment.txt 2>&1
cat /report/environment.txt

if [ $G1_RC -ne 0 ] || [ $G2_RC -ne 0 ]; then
  echo "mandatory apt group failed (g1=$G1_RC g2=$G2_RC)" > /report/FAILED.txt
  exit 1
fi

# Build/boot as a non-root user whose uid/gid match the host checkout.
groupadd -g "${HOST_GID:-1001}" builder 2>/dev/null || true
useradd -m -u "${HOST_UID:-1001}" -g "${HOST_GID:-1001}" builder 2>/dev/null || true

cp /scripts/gate-as-user.sh /tmp/gate-as-user.sh
chmod +x /tmp/gate-as-user.sh
su builder -c /tmp/gate-as-user.sh
BUILD_RC=$?
echo "in-container gate pipeline rc=$BUILD_RC"
exit $BUILD_RC
