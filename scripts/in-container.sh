#!/usr/bin/env bash
# Inside Ubuntu 10.04 (lucid): install the Gingerbread-era build
# environment, then drop privileges to a user matching the host UID so
# the cached tree stays writable by the runner on later runs.
set -x

# Lucid is EOL: its packages live on old-releases.ubuntu.com now.
sed -i -e 's|archive.ubuntu.com|old-releases.ubuntu.com|g' \
       -e 's|security.ubuntu.com|old-releases.ubuntu.com|g' \
       /etc/apt/sources.list

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git-core gnupg flex bison gperf build-essential zip curl unzip file \
  zlib1g-dev libc6-dev lib32ncurses5 lib32z1 lib32readline5-dev \
  x11proto-core-dev libx11-dev libgl1-mesa-dev g++-multilib \
  libxml2-utils xsltproc tofrodos python-markdown perl python bc patch \
  openjdk-6-jdk ia32-libs

{
  echo "== container environment =="
  cat /etc/lsb-release 2>/dev/null
  java -version 2>&1 | head -3
  javac -version 2>&1
  make --version | head -1
  gcc --version | head -1
  python --version 2>&1
  ld --version | head -1
  ls -l /lib/ld-linux.so.2 2>/dev/null || echo "no 32-bit loader"
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
