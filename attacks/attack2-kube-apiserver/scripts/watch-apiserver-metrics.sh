#!/usr/bin/env bash
#
# watch-apiserver-metrics.sh
#
# Live view of nf_conntrack saturation and control-plane CPU usage while
# an attack runs. Read locally (sudo sysctl, top), no kubectl exec, no
# dependency on the apiserver.
#
# Packet loss is not measured here, use tcp-latency-test-nsenter.sh
# (run on k8s-w2) for that.
#
# Live display only, no file output.
#
# Usage: ./watch-apiserver-metrics.sh [interval_seconds]
#   (default interval: 10s)
#
# Ctrl+C to stop watching (does not stop the attack itself).
#

set -uo pipefail

# nf_conntrack saturation ratio (%) above which the live display flags an alert.
CONNTRACK_ALERT_PCT="90"

INTERVAL="${1:-10}"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: do not run this script with 'sudo'. Run it as a normal user."
    echo "  (it uses sudo itself, punctually, for nf_conntrack)"
    exit 1
fi

log "=== Watch started (interval ${INTERVAL}s) ==="
log "Ctrl+C to stop (does not stop the attack)"
echo
printf "%-10s %-16s %-8s %-8s\n" "TIME" "CONNTRACK" "CPU_US" "CPU_SY"
printf "%s\n" "--------------------------------------------"

trap 'echo; log "Watch stopped."; exit 0' INT TERM

while true; do
    now=$(date '+%H:%M:%S')

    conntrack_count=$(sudo sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo "0")
    conntrack_max=$(sudo sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "1")

    cpu_line=$(top -bn1 | grep "%Cpu")
    cpu_us=$(echo "$cpu_line" | grep -oP '[\d,\.]+(?=\s*us)' | tr ',' '.' | head -1)
    cpu_sy=$(echo "$cpu_line" | grep -oP '[\d,\.]+(?=\s*sy)' | tr ',' '.' | head -1)
    cpu_us="${cpu_us:-0}"
    cpu_sy="${cpu_sy:-0}"

    alert=""
    conntrack_pct=$(awk -v c="$conntrack_count" -v m="$conntrack_max" 'BEGIN { printf "%.0f", (m>0 ? (c/m)*100 : 0) }')
    if [ "$conntrack_pct" -ge "$CONNTRACK_ALERT_PCT" ]; then
        alert=" <<< CONNTRACK SATURATED"
    fi

    printf "%-10s %-16s %-8s %-8s%s\n" \
        "$now" "${conntrack_count}/${conntrack_max}" "$cpu_us" "$cpu_sy" "$alert"

    sleep "$INTERVAL"
done
