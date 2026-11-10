#!/usr/bin/env bash
# Inside Ubuntu 12.04 (precise): install the Gingerbread-era build
# environment, then drop privileges to a user matching the host UID so
# the cached tree stays writable by the runner on later runs.
#
# Why 12.04 and not 10.04: Docker Hub's ubuntu:10.04 image is still
# manifest v2 schema 1, which modern Docker refuses to pull. 12.04 is
# schema 2 and is itself an era-documented GB build environment
# (GNU make 3.81, OpenJDK 6, gcc 4.6).
set -x

# Precise is EOL: its packages live on old-releases.ubuntu.com now.
sed -i -e 's|archive.ubuntu.com|old-releases.ubuntu.com|g' \
       -e 's|security.ubuntu.com|old-releases.ubuntu.com|g' \
       /etc/apt/sources.list

dpkg --add-architecture i386 2>/dev/null || true
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git-core gnupg flex bison gperf build-essential zip curl unzip file \
  libc6-dev libncurses5-dev:i386 x11proto-core-dev libx11-dev:i386 \
  libreadline6-dev:i386 libgl1-mesa-glx:i386 libgl1-mesa-dev \
  g++-multilib zlib1g-dev:i386 zlib1g-dev \
  libxml2-utils xsltproc tofrodos python-markdown perl python bc patch \
  openjdk-6-jdk

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

# Build as a non-root user whose uid/gid match the host checkout owner.
groupadd -g "${HOST_GID:-1001}" builder 2>/dev/null || true
useradd -m -u "${HOST_UID:-1001}" -g "${HOST_GID:-1001}" builder 2>/dev/null || true

cp /scripts/build-as-user.sh /tmp/build-as-user.sh
chmod +x /tmp/build-as-user.sh
su builder -c /tmp/build-as-user.sh
BUILD_RC=$?
echo "in-container build rc=$BUILD_RC"
exit $BUILD_RC
