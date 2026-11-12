#!/usr/bin/env bash
# Host side, always runs: assemble report/SUMMARY.txt from the pieces
# the earlier phases wrote, compute the disk peak from the sampler
# log, and attach the full build log if it is not oversized.
set -x
mkdir -p report

# Full build log into the report (tail if huge).
if [ -f aosp/out-build.log ]; then
  SZ=$(stat -c%s aosp/out-build.log)
  if [ "$SZ" -le 8000000 ]; then
    cp aosp/out-build.log report/build-log-full.txt
  else
    tail -c 8000000 aosp/out-build.log > report/build-log-full.txt
  fi
fi

# Disk peak: sampler recorded epoch + avail bytes every 30 s.
PEAK_LINE="disk peak: no samples"
if [ -s report/disk-samples.txt ]; then
  PEAK_LINE=$(python3 - <<'EOF'
lines = [l.split() for l in open('report/disk-samples.txt') if l.strip()]
pairs = [(int(x[0]), int(x[1])) for x in lines if len(x) == 2]
if pairs:
    first = pairs[0][1]
    low = min(b for _, b in pairs)
    print("disk: avail start=%.2f GiB min=%.2f GiB -> peak used by job ~= %.2f GiB (samples=%d)"
          % (first/2**30, low/2**30, (first-low)/2**30, len(pairs)))
else:
    print("disk peak: samples unparsable")
EOF
)
fi
echo "$PEAK_LINE" > report/disk-peak.txt

{
  echo "=== kitkat parts probe summary ==="
  cat report/FAILED.txt 2>/dev/null
  cat report/sync-result.txt 2>/dev/null
  cat report/build-wallclock.txt 2>/dev/null
  cat report/make-result.txt 2>/dev/null
  cat report/disk-peak.txt 2>/dev/null
  echo "tree size after sync: see sync-projects.txt"
  echo "out/ size: $(cat report/out-size.txt 2>/dev/null || echo n/a)"
  echo
  cat report/verify.txt 2>/dev/null || echo "verify.txt missing (build never reached verification)"
  echo
  grep -q "ALL MODULES OK" report/verdict.txt 2>/dev/null \
    && echo "ALL MODULES OK" || echo "NOT ALL MODULES OK"
} > report/SUMMARY.txt
cat report/SUMMARY.txt
