#!/usr/bin/env bash
# Host side: run the era container with the partially synced tree
# mounted in. Samples free disk every 30 s for the whole build and
# self-protects: if free space falls under ~1.2 GB the container is
# killed and a FAILED marker is written, so the job reports instead
# of being hard-killed by the system.
set -x

mkdir -p report
: > report/disk-samples.txt

(
  while :; do
    echo "$(date +%s) $(df -B1 --output=avail . | tail -1)" \
      >> report/disk-samples.txt
    sleep 30
  done
) &
SAMPLER_PID=$!

(
  while :; do
    AVAIL=$(df -B1 --output=avail . | tail -1)
    if [ "$AVAIL" -lt 1200000000 ]; then
      echo "disk guard tripped: avail=$AVAIL" > report/FAILED.txt
      docker kill kkparts 2>/dev/null
      break
    fi
    sleep 20
  done
) &
GUARD_PID=$!

START=$(date +%s)
docker run --rm --name kkparts \
  -v "$PWD/aosp:/aosp" \
  -v "$PWD/kitkat:/scripts:ro" \
  -v "$PWD/report:/report" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  ubuntu:12.04 \
  bash /scripts/in-container.sh
RC=$?
END=$(date +%s)
echo "container build rc=$RC elapsed=$((END - START))s" \
  | tee report/build-wallclock.txt

kill $SAMPLER_PID $GUARD_PID 2>/dev/null
exit $RC
