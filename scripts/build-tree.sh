#!/usr/bin/env bash
# Host side: run the era container with the synced tree mounted in.
set -e -x

mkdir -p report

docker run --rm \
  -v "$PWD/aosp:/aosp" \
  -v "$PWD/scripts:/scripts:ro" \
  -v "$PWD/report:/report" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  ubuntu:12.04 \
  bash /scripts/in-container.sh
