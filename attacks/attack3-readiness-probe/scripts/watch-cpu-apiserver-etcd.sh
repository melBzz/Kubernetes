#!/usr/bin/env bash
#
# watch-cpu-apiserver-etcd.sh
#
# Live view of kube-apiserver and etcd process CPU usage, computed as a
# CPU-tick delta over each interval (/proc/<pid>/stat), same method as
# capture-cpu-loop-attack3.sh. Run on k8s-cp, with sudo.
#
# Live display only, no file output.
#
# Usage: ./watch-cpu-apiserver-etcd.sh [interval_seconds]
#   (default interval: 10s)
#
# Ctrl+C to stop watching (does not stop the attack itself).

INTERVAL="${1:-10}"
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

PREV_APISERVER=$(proc_ticks kube-apiserver)
PREV_ETCD=$(proc_ticks etcd)

while true; do
    sleep "$INTERVAL"
    TS=$(date +%H:%M:%S)

    CUR_APISERVER=$(proc_ticks kube-apiserver)
    CUR_ETCD=$(proc_ticks etcd)

    DELTA_APISERVER=$((CUR_APISERVER - PREV_APISERVER))
    DELTA_ETCD=$((CUR_ETCD - PREV_ETCD))

    CPU_APISERVER=$(echo "scale=1; $DELTA_APISERVER * 100 / ($INTERVAL * $HZ)" | bc)
    CPU_ETCD=$(echo "scale=1; $DELTA_ETCD * 100 / ($INTERVAL * $HZ)" | bc)

    echo "${TS} kube-apiserver=${CPU_APISERVER}% etcd=${CPU_ETCD}%"

    PREV_APISERVER=$CUR_APISERVER
    PREV_ETCD=$CUR_ETCD
done
