#!/usr/bin/env bash
#
# capture-iptables-snapshot.sh
#
# Snapshots the local node's iptables rule count, as evidence that
# kube-proxy flushed/reprogrammed its local rules in response to the
# attack ("the kube-proxy flushes all worker nodes' iptables",
# Section 4.5). Run separately on each worker node (k8s-w1, k8s-w2),
# with sudo. Takes 5 snapshots, 10s apart, and appends each one as a
# row to <label>_iptables_<hostname>.csv, next to this script.
#
# Usage: ./capture-iptables-snapshot.sh [label] [count] [interval_seconds]
#   label    : default "run"
#   count    : default 5
#   interval : default 10s

LABEL="${1:-run}"
COUNT="${2:-5}"
INTERVAL="${3:-10}"
HOST=$(hostname)
OUT_FILE="${LABEL}_iptables_${HOST}.csv"

if [[ ! -f "$OUT_FILE" ]]; then
    echo "timestamp,total_rules,endpoints_flood_svc_rules" > "$OUT_FILE"
fi

for i in $(seq 1 "$COUNT"); do
    TS=$(date +%H:%M:%S)
    TOTAL=$(sudo iptables-save | wc -l)
    SVC_RULES=$(sudo iptables-save | grep -c "endpoints-flood-svc" || true)

    echo "${TS},${TOTAL},${SVC_RULES}" >> "$OUT_FILE"
    echo "[$LABEL] ${HOST} ${TS} total_rules=${TOTAL} endpoints_flood_svc_rules=${SVC_RULES}"

    if [[ $i -lt $COUNT ]]; then
        sleep "$INTERVAL"
    fi
done

echo "Done -> $OUT_FILE"
