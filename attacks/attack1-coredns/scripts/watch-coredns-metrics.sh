#!/usr/bin/env bash
#
# watch-coredns-metrics.sh
#
# Monitors in real time, at a regular interval, all the
# CoreDNS metrics relevant to the attack.
#
# Usage: ./watch-coredns-metrics.sh [interval_seconds]
#   (default interval: 10s)
#
# Ctrl+C to stop monitoring (does not stop the attack itself).
#

set -uo pipefail

SAFE_NS="safe-ns"
SAFE_POD="safe-pod"
COREDNS_SVC_IP="10.96.0.10"
COREDNS_METRICS_PORT="9153"

INTERVAL="${1:-10}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$HOME/results/attack1/watch_${TIMESTAMP}"
RAW_DIR="$LOG_DIR/raw"
mkdir -p "$RAW_DIR"
CSV_FILE="$LOG_DIR/metrics_timeline.csv"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: do not run this script with 'sudo'. Run it as a normal user."
    echo "  (it will use sudo itself briefly for nf_conntrack)"
    exit 1
fi

if ! kubectl get nodes >/dev/null 2>&1; then
    echo "ERROR: kubectl cannot reach the cluster."
    exit 1
fi

sum_metric() {
    local pattern="$1"
    echo "$metrics" | grep "^${pattern}" | grep -v '^#' | awk '{sum+=$NF} END {printf "%s", (NR>0 ? sum : 0)}'
}

sum_metric_label() {
    local pattern="$1" label="$2"
    echo "$metrics" | grep "^${pattern}" | grep -v '^#' | grep -F "$label" | awk '{sum+=$NF} END {printf "%s", (NR>0 ? sum : 0)}'
}

echo "timestamp,rejects_total,proxy_conn_cache_misses_total,proxy_req_duration_count,proxy_req_duration_sum,dns_requests_A,dns_requests_AAAA,dns_requests_other,dns_responses_NOERROR,dns_responses_NXDOMAIN,dns_responses_SERVFAIL,dns_responses_other,cache_entries_denial,cache_entries_success,cache_requests_total,cache_misses_total,dns_req_duration_sum,dns_req_duration_count,conntrack_count,conntrack_max" > "$CSV_FILE"

log "=== Monitoring started (interval ${INTERVAL}s) ==="
log "Structured CSV: $CSV_FILE"
log "Full raw dumps: $RAW_DIR/"
log "Ctrl+C to stop (does not stop the attack)"
echo
printf "%-10s %-9s %-16s %-10s %-10s %-8s\n" "TIME" "REJECTS" "CONNTRACK" "DNS_REQ" "CACHE_MISS" "SERVFAIL"
printf "%s\n" "----------------------------------------------------------------------"

trap 'echo; log "Monitoring stopped."; log "CSV: $CSV_FILE"; log "Raw: $RAW_DIR/"; exit 0' INT TERM

while true; do
    now=$(date '+%H:%M:%S')
    now_iso=$(date '+%Y-%m-%d %H:%M:%S')

    metrics=""
    for attempt in 1 2; do
        metrics=$(kubectl exec -n "$SAFE_NS" "$SAFE_POD" -- \
            sh -c "wget -qO- http://${COREDNS_SVC_IP}:${COREDNS_METRICS_PORT}/metrics" 2>&1)
        if [ -n "$metrics" ] && ! echo "$metrics" | grep -qE "refused|Forbidden|error"; then
            break
        fi
        sleep 1
    done

    echo "$metrics" > "$RAW_DIR/${now_iso//[: ]/_}.txt"

    rejects=$(sum_metric "coredns_forward_max_concurrent_rejects_total")
    proxy_conn_cache_misses=$(sum_metric "coredns_proxy_conn_cache_misses_total")
    proxy_req_dur_count=$(sum_metric "coredns_proxy_request_duration_seconds_count")
    proxy_req_dur_sum=$(sum_metric "coredns_proxy_request_duration_seconds_sum")

    dns_req_total=$(sum_metric "coredns_dns_requests_total")
    dns_req_a=$(sum_metric_label "coredns_dns_requests_total" 'type="A"')
    dns_req_aaaa=$(sum_metric_label "coredns_dns_requests_total" 'type="AAAA"')
    dns_req_other=$(awk -v t="$dns_req_total" -v a="$dns_req_a" -v aa="$dns_req_aaaa" 'BEGIN{printf "%s", t-a-aa}')

    dns_resp_total=$(sum_metric "coredns_dns_responses_total")
    dns_resp_noerror=$(sum_metric_label "coredns_dns_responses_total" 'rcode="NOERROR"')
    dns_resp_nxdomain=$(sum_metric_label "coredns_dns_responses_total" 'rcode="NXDOMAIN"')
    dns_resp_servfail=$(sum_metric_label "coredns_dns_responses_total" 'rcode="SERVFAIL"')
    dns_resp_other=$(awk -v t="$dns_resp_total" -v n="$dns_resp_noerror" -v x="$dns_resp_nxdomain" -v s="$dns_resp_servfail" 'BEGIN{printf "%s", t-n-x-s}')

    cache_entries_denial=$(sum_metric_label "coredns_cache_entries" 'type="denial"')
    cache_entries_success=$(sum_metric_label "coredns_cache_entries" 'type="success"')

    cache_requests=$(sum_metric "coredns_cache_requests_total")
    cache_misses=$(sum_metric "coredns_cache_misses_total")

    dns_req_dur_sum=$(sum_metric "coredns_dns_request_duration_seconds_sum")
    dns_req_dur_count=$(sum_metric "coredns_dns_request_duration_seconds_count")

    conntrack_count=$(sudo sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo "0")
    conntrack_max=$(sudo sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "0")

    alert=""
    if [ -n "$rejects" ] && [ "$rejects" != "0" ]; then
        alert=" <<< REJECTS DETECTED!"
    fi

    printf "%-10s %-9s %-16s %-10s %-10s %-8s%s\n" \
        "$now" "$rejects" "${conntrack_count}/${conntrack_max}" "$dns_req_total" "$cache_misses" "$dns_resp_servfail" "$alert"

    echo "${now_iso},${rejects},${proxy_conn_cache_misses},${proxy_req_dur_count},${proxy_req_dur_sum},${dns_req_a},${dns_req_aaaa},${dns_req_other},${dns_resp_noerror},${dns_resp_nxdomain},${dns_resp_servfail},${dns_resp_other},${cache_entries_denial},${cache_entries_success},${cache_requests},${cache_misses},${dns_req_dur_sum},${dns_req_dur_count},${conntrack_count},${conntrack_max}" >> "$CSV_FILE"

    sleep "$INTERVAL"
done
