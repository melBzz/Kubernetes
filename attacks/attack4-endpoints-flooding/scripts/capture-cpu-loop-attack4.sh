#!/usr/bin/env bash
#
# capture-cpu-loop-attack4.sh
#
# Samples CPU usage of the kube-apiserver process specifically (not
# whole-system CPU), looped over time and written to CSV. Computed as a
# CPU-tick delta over each interval (/proc/<pid>/stat), same method as
# the other attacks. kube-apiserver is the only control-plane process
# explicitly named in the paper's mechanism for this attack ("the
# kube-apiserver components send requests to kube-proxy", Section 4.5).
# Run on k8s-cp.
#
# Usage: ./capture-cpu-loop-attack4.sh [label] [interval_seconds] [duration_seconds]
#   label    : default "run"
#   interval : default 10s
#   duration : default 300s

set -euo pipefail

LABEL="${1:-run}"
INTERVAL="${2:-10}"
DURATION="${3:-300}"
OUT_FILE="${LABEL}_cpu_loop.csv"

HZ=$(getconf CLK_TCK)

apiserver_ticks() {
    local total=0
    local pid rest fields utime stime
    for pid in $(pgrep -x kube-apiserver); do
        rest=$(</proc/"$pid"/stat)
        rest="${rest##*) }"
        read -ra fields <<< "$rest"
        utime=${fields[11]}
        stime=${fields[12]}
        total=$((total + utime + stime))
    done
    echo "$total"
}

echo "timestamp,cpu_kube_apiserver" > "$OUT_FILE"

END=$((SECONDS + DURATION))
PREV_TICKS=$(apiserver_ticks)

while [[ $SECONDS -lt $END ]]; do
    sleep "$INTERVAL"
    TS=$(date +%H:%M:%S)
    CUR_TICKS=$(apiserver_ticks)
    DELTA=$((CUR_TICKS - PREV_TICKS))
    CPU_APISERVER=$(echo "scale=1; $DELTA * 100 / ($INTERVAL * $HZ)" | bc)

    echo "${TS},${CPU_APISERVER}" >> "$OUT_FILE"
    echo "${TS} kube-apiserver=${CPU_APISERVER}%"

    PREV_TICKS=$CUR_TICKS
done

echo "Done -> $OUT_FILE"
