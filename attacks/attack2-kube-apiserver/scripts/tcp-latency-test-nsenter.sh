#!/usr/bin/env bash
#
# tcp-latency-test-nsenter.sh
#
# TCP connectivity + latency test against the control plane, run on
# k8s-w2 (the node hosting safe-pod), using nsenter instead of kubectl
# exec, so it does not depend on the apiserver.
#
# Must be run ON k8s-w2 itself, not from k8s-cp.
#
# Usage: sudo ./tcp-latency-test-nsenter.sh [attempts]
#   attempts : number of connection attempts, default 20
#

set -uo pipefail

POD_NAME_FILTER="safe"
CONTROL_PLANE_IP="10.10.10.10"
CONTROL_PLANE_PORT="6443"
CONN_TIMEOUT="1"

ATTEMPTS="${1:-20}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this with sudo (crictl and nsenter both need root)."
    exit 1
fi

if ! command -v crictl >/dev/null 2>&1; then
    echo "ERROR: crictl not found. Are you on the right node (k8s-w2)?"
    exit 1
fi

CONTAINER_ID=$(crictl ps --name "$POD_NAME_FILTER" -q | head -1)
if [ -z "$CONTAINER_ID" ]; then
    echo "ERROR: no running container matching name '$POD_NAME_FILTER' found on this node."
    echo "  Check with: crictl ps"
    exit 1
fi

PID=$(crictl inspect "$CONTAINER_ID" | grep -oP '"pid":\s*\K[0-9]+' | head -1)
if [ -z "$PID" ]; then
    echo "ERROR: could not determine the container's PID."
    exit 1
fi

echo "Container: $CONTAINER_ID (pid $PID)"
echo "Testing ${ATTEMPTS} TCP connection(s) to ${CONTROL_PLANE_IP}:${CONTROL_PLANE_PORT} from inside the pod's own netns..."
echo

ok=0
total_ms=0
max_ms=0

for i in $(seq 1 "$ATTEMPTS"); do
    start=$(awk '{print $1}' /proc/uptime)
    if nsenter -t "$PID" -n nc -z -w"$CONN_TIMEOUT" "$CONTROL_PLANE_IP" "$CONTROL_PLANE_PORT" 2>/dev/null; then
        status="OK"
        ok=$((ok + 1))
    else
        status="FAIL"
    fi
    end=$(awk '{print $1}' /proc/uptime)
    elapsed_ms=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.0f", (e - s) * 1000 }')
    total_ms=$(awk -v t="$total_ms" -v x="$elapsed_ms" 'BEGIN { printf "%.0f", t + x }')
    if [ "$elapsed_ms" -gt "$max_ms" ]; then
        max_ms=$elapsed_ms
    fi
    printf "attempt %2d : %-4s  %5sms\n" "$i" "$status" "$elapsed_ms"
done

echo
echo "$ok/$ATTEMPTS connections succeeded"
avg_ms=$(awk -v t="$total_ms" -v n="$ATTEMPTS" 'BEGIN { printf "%.0f", (n > 0 ? t / n : 0) }')
echo "average latency : ${avg_ms}ms  (max: ${max_ms}ms)"
