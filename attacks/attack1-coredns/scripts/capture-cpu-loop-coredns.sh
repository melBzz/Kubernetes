#!/usr/bin/env bash
#
# capture-cpu-loop-coredns.sh
#
# Samples CPU usage of the coredns process specifically (not whole-system
# CPU), looped over time and written to CSV. Computed as a CPU-tick delta
# over each interval (/proc/<pid>/stat).
#
# Usage: ./capture-cpu-loop-coredns.sh [label] [interval_seconds] [duration_seconds]
#   label    : default "run"
#   interval : default 10s
#   duration : default 300s

set -euo pipefail

LABEL="${1:-run}"
INTERVAL="${2:-10}"
DURATION="${3:-300}"
OUT_FILE="${LABEL}_cpu_loop.csv"

HZ=$(getconf CLK_TCK)

coredns_ticks() {
    local total=0
    local pid rest fields utime stime
    for pid in $(pgrep -x coredns); do
        rest=$(</proc/"$pid"/stat)
        rest="${rest##*) }"
        read -ra fields <<< "$rest"
        utime=${fields[11]}
        stime=${fields[12]}
        total=$((total + utime + stime))
    done
    echo "$total"
}

echo "timestamp,cpu_coredns" > "$OUT_FILE"

END=$((SECONDS + DURATION))
PREV_TICKS=$(coredns_ticks)

while [[ $SECONDS -lt $END ]]; do
    sleep "$INTERVAL"
    TS=$(date +%H:%M:%S)
    CUR_TICKS=$(coredns_ticks)
    DELTA=$((CUR_TICKS - PREV_TICKS))
    CPU_COREDNS=$(echo "scale=1; $DELTA / ($INTERVAL * $HZ) * 100" | bc)

    echo "${TS},${CPU_COREDNS}" >> "$OUT_FILE"
    echo "${TS} coredns=${CPU_COREDNS}%"

    PREV_TICKS=$CUR_TICKS
done

echo "Done -> $OUT_FILE"
