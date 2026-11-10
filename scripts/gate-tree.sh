#!/usr/bin/env bash
# Host side: run the era container with the synced (and patched) tree,
# the era SDK (emulator) and the gate report directory mounted in.
set -e -x

mkdir -p gate-report

docker run --rm \
  -v "$PWD/aosp:/aosp" \
  -v "$PWD/scripts:/scripts:ro" \
  -v "$PWD/sdk:/sdk:ro" \
  -v "$PWD/gate-report:/report" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  ubuntu:12.04 \
  bash /scripts/in-container-gate.sh
