#!/usr/bin/env bash
#
# capture-tcp-loss-loop-nsenter.sh
#
# TCP packet-loss probe against the control plane, looped over time and
# written to CSV. Run on k8s-w2 (the victim pod's node), using nsenter
# instead of kubectl exec, so it does not depend on the apiserver.
#
# conntrack and CPU are not collected here.
# (run on k8s-cp in parallel) for those.
#
# Must be run ON k8s-w2, with sudo.
#
# Usage: sudo ./capture-tcp-loss-loop-nsenter.sh [label] [interval_seconds] [duration_seconds] [attempts_per_sample]
#   label      : run name (e.g. "before", "after"), default "run"
#   interval   : default 20s
#   duration   : default 120s, auto-stop
#   attempts   : TCP connection attempts per sample, default 20
#

set -uo pipefail

POD_NAME_FILTER="safe"
CONTROL_PLANE_IP="10.10.10.10"
CONTROL_PLANE_PORT="6443"
CONN_TIMEOUT="1"

LABEL="${1:-run}"
INTERVAL="${2:-20}"
DURATION="${3:-120}"
ATTEMPTS="${4:-20}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="$HOME/results/attack2/tcploss_${LABEL}_${TIMESTAMP}"
mkdir -p "$OUT_DIR"
CSV_FILE="$OUT_DIR/tcp_loss_loop.csv"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this with sudo (crictl and nsenter both need root)."
    exit 1
fi

if ! command -v crictl >/dev/null 2>&1; then
    echo "ERROR: crictl not found. Are you on the right node (k8s-w2)?"
    exit 1
fi

echo "timestamp,tcp_probe_status,tcp_probe_attempts,tcp_probe_success,tcp_probe_loss_pct" > "$CSV_FILE"

log "=== TCP loss loop capture started (label: $LABEL, interval: ${INTERVAL}s) ==="
log "Duration: ${DURATION}s (auto-stop, Ctrl+C also works)"
log "CSV: $CSV_FILE"
echo
printf "%-10s %-8s %-10s\n" "TIME" "STATUS" "LOSS_%"
printf "%s\n" "------------------------------"

n_ok=0
n_error=0

print_summary() {
    local total=$((n_ok + n_error))
    echo
    log "=== Capture finished. ${total} sample(s) total ==="
    if [ "$total" -gt 0 ]; then
        awk -v ok="$n_ok" -v err="$n_error" -v tot="$total" 'BEGIN {
            printf "  Sample success rate : %.1f%% (%d/%d OK)\n", (ok/tot)*100, ok, tot
            printf "  Errors (no running victim container found) : %.1f%% (%d/%d)\n", (err/tot)*100, err, tot
        }'
    fi
    echo
    log "Average computed only over OK samples:"
    awk -F',' '
        $2=="OK" {
            loss+=$5; n++
        }
        END {
            if (n>0) {
                printf "  TCP packet loss (control plane) : mean=%.1f%% over %d sample(s)\n", loss/n, n
            } else {
                print "  (no OK sample on this capture)"
            }
        }' "$CSV_FILE"
    log "Full detail: $CSV_FILE"
}

trap 'print_summary; exit 0' INT TERM

# One sample: resolve the victim container, run ATTEMPTS connections from
# inside its network namespace.
tcp_loss_sample() {
    local container_id pid ok=0 i status

    container_id=$(crictl ps --name "$POD_NAME_FILTER" -q 2>/dev/null | head -1)
    if [ -z "$container_id" ]; then
        echo "ERROR::"
        return
    fi

    pid=$(crictl inspect "$container_id" 2>/dev/null | grep -oP '"pid":\s*\K[0-9]+' | head -1)
    if [ -z "$pid" ]; then
        echo "ERROR::"
        return
    fi

    ok=0
    i=0
    while [ "$i" -lt "$ATTEMPTS" ]; do
        if nsenter -t "$pid" -n nc -z -w"$CONN_TIMEOUT" "$CONTROL_PLANE_IP" "$CONTROL_PLANE_PORT" 2>/dev/null; then
            ok=$((ok + 1))
        fi
        i=$((i + 1))
    done

    status="OK"
    echo "${status}:${ATTEMPTS}:${ok}"
}

START_TS=$(date +%s)

while true; do
    now=$(date '+%H:%M:%S')
    now_iso=$(date '+%Y-%m-%d %H:%M:%S')

    sample=$(tcp_loss_sample)
    tcp_probe_status="${sample%%:*}"
    rest="${sample#*:}"
    tcp_probe_attempts="${rest%%:*}"
    tcp_probe_success="${rest#*:}"

    if [ "$tcp_probe_status" = "OK" ]; then
        n_ok=$((n_ok + 1))
        tcp_probe_loss_pct=$(awk -v ok="$tcp_probe_success" -v tot="$tcp_probe_attempts" 'BEGIN { printf "%.1f", ((tot-ok)/tot)*100 }')
        loss_display="${tcp_probe_loss_pct}"
    else
        n_error=$((n_error + 1))
        tcp_probe_attempts=""
        tcp_probe_success=""
        tcp_probe_loss_pct=""
        loss_display="n/a (no victim container found)"
    fi

    printf "%-10s %-8s %-10s\n" "$now" "$tcp_probe_status" "$loss_display"
    echo "${now_iso},${tcp_probe_status},${tcp_probe_attempts},${tcp_probe_success},${tcp_probe_loss_pct}" >> "$CSV_FILE"

    now_ts=$(date +%s)
    elapsed=$((now_ts - START_TS))
    if [ "$elapsed" -ge "$DURATION" ]; then
        break
    fi

    sleep "$INTERVAL"
done

print_summary
