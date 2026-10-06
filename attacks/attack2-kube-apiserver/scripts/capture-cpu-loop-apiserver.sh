#!/usr/bin/env bash
#
# capture-cpu-loop-apiserver.sh
#
# Samples CPU usage of the kube-apiserver and etcd processes specifically
# (not whole-system CPU), looped over time and written to CSV. Computed
# as a CPU-tick delta over each interval (/proc/<pid>/stat). Run on k8s-cp.
#
# DEBUG=1 ./capture-cpu-loop-apiserver.sh prints raw tick deltas to
# stderr alongside the normal output, to diagnose readings that look
# wrong.
#
# Usage: ./capture-cpu-loop-apiserver.sh [label] [interval_seconds] [duration_seconds]
#   label    : default "run"
#   interval : default 10s
#   duration : default 300s

set -euo pipefail

LABEL="${1:-run}"
INTERVAL="${2:-10}"
DURATION="${3:-300}"
OUT_FILE="${LABEL}_cpu_loop.csv"
DEBUG="${DEBUG:-0}"

HZ=$(getconf CLK_TCK)

proc_ticks() {
    local name="$1"
    local total=0
    local pid rest fields utime stime
    for pid in $(pgrep -x "$name"); do
        rest=$(</proc/"$pid"/stat)
        rest="${rest##*) }"
        read -ra fields <<< "$rest"
        utime=${fields[11]}
        stime=${fields[12]}
        total=$((total + utime + stime))
    done
    echo "$total"
}

echo "timestamp,cpu_kube_apiserver,cpu_etcd,cpu_total" > "$OUT_FILE"

END=$((SECONDS + DURATION))
PREV_APISERVER=$(proc_ticks kube-apiserver)
PREV_ETCD=$(proc_ticks etcd)

[[ "$DEBUG" == "1" ]] && echo "[debug] initial PREV_APISERVER=$PREV_APISERVER PREV_ETCD=$PREV_ETCD" >&2

while [[ $SECONDS -lt $END ]]; do
    sleep "$INTERVAL"
    TS=$(date +%H:%M:%S)

    CUR_APISERVER=$(proc_ticks kube-apiserver)
    CUR_ETCD=$(proc_ticks etcd)

    DELTA_APISERVER=$((CUR_APISERVER - PREV_APISERVER))
    DELTA_ETCD=$((CUR_ETCD - PREV_ETCD))

    [[ "$DEBUG" == "1" ]] && echo "[debug] CUR_ETCD=$CUR_ETCD PREV_ETCD=$PREV_ETCD DELTA_ETCD=$DELTA_ETCD" >&2

    CPU_APISERVER=$(echo "scale=1; $DELTA_APISERVER * 100 / ($INTERVAL * $HZ)" | bc)
    CPU_ETCD=$(echo "scale=1; $DELTA_ETCD * 100 / ($INTERVAL * $HZ)" | bc)
    CPU_TOTAL=$(echo "$CPU_APISERVER + $CPU_ETCD" | bc)

    echo "${TS},${CPU_APISERVER},${CPU_ETCD},${CPU_TOTAL}" >> "$OUT_FILE"
    echo "${TS} kube-apiserver=${CPU_APISERVER}% etcd=${CPU_ETCD}% total=${CPU_TOTAL}%"

    PREV_APISERVER=$CUR_APISERVER
    PREV_ETCD=$CUR_ETCD
done

echo "Done -> $OUT_FILE"
