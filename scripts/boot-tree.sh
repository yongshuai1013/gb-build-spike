#!/usr/bin/env bash
# Host side: run the era container with the synced tree, the era SDK
# (emulator) and the boot report directory mounted in.
set -e -x

mkdir -p boot-report

docker run --rm \
  -v "$PWD/aosp:/aosp" \
  -v "$PWD/scripts:/scripts:ro" \
  -v "$PWD/sdk:/sdk:ro" \
  -v "$PWD/boot-report:/report" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  ubuntu:12.04 \
  bash /scripts/in-container-boot.sh
