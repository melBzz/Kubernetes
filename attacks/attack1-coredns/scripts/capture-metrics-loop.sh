#!/usr/bin/env bash
#
# capture-metrics-loop.sh
#
# Loop capture, every N seconds, of key metrics into a CSV to
# compute averages. Each sample includes a
# TCP availability measurement of the control plane (packet loss),
# following the OK/TIMEOUT/ERROR protocol;
#
# Usage: ./capture-metrics-loop.sh [label] [interval_seconds] [duration_seconds]
#   label      : run name (e.g. "before", "after") - default "run"
#   interval   : default 20s
#   duration   : default 120s (2min), auto stop
#

set -uo pipefail

SAFE_NS="safe-ns"
SAFE_POD="safe-pod"
COREDNS_SVC_IP="10.96.0.10"
COREDNS_METRICS_PORT="9153"

# TCP probe target: the control plane virtual IP as seen
# from inside the cluster
CONTROL_PLANE_IP="10.10.10.10"
CONTROL_PLANE_PORT="6443"
TCP_PROBE_COUNT="${TCP_PROBE_COUNT:-20}"     # number of TCP attempts per sample
TCP_PROBE_CONN_TIMEOUT="1"                   # timeout (s) for each nc -z -w attempt

LABEL="${1:-run}"
INTERVAL="${2:-20}"
DURATION="${3:-120}"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-15}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="$HOME/results/attack1/loop_${LABEL}_${TIMESTAMP}"
mkdir -p "$OUT_DIR"
CSV_FILE="$OUT_DIR/metrics_loop.csv"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: do not run this script with 'sudo'."
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

echo "timestamp,fetch_status,rejects_total,conntrack_count,conntrack_max,cpu_us,cpu_sy,dns_req_total,cache_misses,dns_resp_servfail,proxy_conn_cache_misses,cache_requests,dns_req_dur_sum,dns_req_dur_count,tcp_probe_status,tcp_probe_attempts,tcp_probe_success,tcp_probe_loss_pct" > "$CSV_FILE"

log "=== Loop capture started (label: $LABEL, interval: ${INTERVAL}s) ==="
log "Duration: ${DURATION}s (auto stop, Ctrl+C also works)"
log "CSV: $CSV_FILE"
echo
printf "%-10s %-9s %-9s %-16s %-8s %-8s %-10s %-14s\n" "TIME" "STATUS" "REJECTS" "CONNTRACK" "CPU_US" "CPU_SY" "DNS_REQ" "TCP_LOSS_%"
printf "%s\n" "--------------------------------------------------------------------------------------"

n_ok=0
n_timeout=0
n_error=0

print_summary() {
    local total_attempts=$((n_ok + n_timeout + n_error))
    echo
    log "=== Capture finished. ${total_attempts} attempt(s) total ==="
    if [ "$total_attempts" -gt 0 ]; then
        awk -v ok="$n_ok" -v to="$n_timeout" -v err="$n_error" -v tot="$total_attempts" 'BEGIN {
            printf "  Success rate (fetch metrics) : %.1f%% (%d/%d OK)\n", (ok/tot)*100, ok, tot
            printf "  Timeouts : %.1f%% (%d/%d)\n", (to/tot)*100, to, tot
            printf "  Errors   : %.1f%% (%d/%d)\n", (err/tot)*100, err, tot
        }'
    fi
    echo
    log "Averages computed only on OK samples:"
    awk -F',' '
        $2=="OK" {
            rej+=$3; ct+=$4; us+=$6; sy+=$7; req+=$8; miss+=$9; sf+=$10; n++
        }
        $15=="OK" {
            tprobe_ok+=$18; ntprobe++
        }
        END {
            if (n>0) {
                printf "  rejects_total      : average=%.1f\n", rej/n
                printf "  conntrack_count    : average=%.0f\n", ct/n
                printf "  CPU us+sy (%%)      : average us=%.1f  sy=%.1f\n", us/n, sy/n
                printf "  dns_requests_total : average=%.0f\n", req/n
                printf "  cache_misses_total : average=%.0f\n", miss/n
                printf "  dns_responses SERVFAIL : average=%.1f\n", sf/n
            } else {
                print "  (no OK sample in this capture)"
            }
            if (ntprobe>0) {
                printf "  TCP packet loss (control plane) : average=%.1f%%\n", tprobe_ok/ntprobe
            } else {
                print "  (no OK TCP probe in this capture)"
            }
        }' "$CSV_FILE"
    log "Full detail: $CSV_FILE"
}

trap 'print_summary; exit 0' INT TERM

# TCP availability probe of the control plane, run from the
# victim pod (safe-pod). Sends TCP_PROBE_COUNT attempts of nc -z -w1 and
# retrieves the number of successes. Classification
# OK/TIMEOUT/ERROR same as the metrics fetch;
tcp_probe() {
    local result=""
    local status="ERROR"
    if result=$(timeout "$FETCH_TIMEOUT" kubectl exec -n "$SAFE_NS" "$SAFE_POD" -- \
        sh -c "ok=0; i=0; while [ \$i -lt $TCP_PROBE_COUNT ]; do nc -z -w${TCP_PROBE_CONN_TIMEOUT} ${CONTROL_PLANE_IP} ${CONTROL_PLANE_PORT} 2>/dev/null && ok=\$((ok+1)); i=\$((i+1)); done; echo \$ok" 2>&1); then
        if echo "$result" | tail -1 | grep -qE '^[0-9]+$'; then
            status="OK"
        else
            status="ERROR"
            result=""
        fi
    else
        local exit_code=$?
        if [ "$exit_code" -eq 124 ]; then
            status="TIMEOUT"
        else
            status="ERROR"
        fi
        result=""
    fi
    echo "${status}:${result}"
}

START_TS=$(date +%s)

while true; do
    now=$(date '+%H:%M:%S')
    now_iso=$(date '+%Y-%m-%d %H:%M:%S')

    metrics=""
    fetch_status="ERROR"
    if metrics=$(timeout "$FETCH_TIMEOUT" kubectl exec -n "$SAFE_NS" "$SAFE_POD" -- \
        sh -c "wget -qO- http://${COREDNS_SVC_IP}:${COREDNS_METRICS_PORT}/metrics" 2>&1); then
        if [ -n "$metrics" ] && echo "$metrics" | grep -q "^coredns_"; then
            fetch_status="OK"
            n_ok=$((n_ok+1))
        else
            fetch_status="ERROR"
            n_error=$((n_error+1))
        fi
    else
        exit_code=$?
        if [ "$exit_code" -eq 124 ]; then
            fetch_status="TIMEOUT"
            n_timeout=$((n_timeout+1))
        else
            fetch_status="ERROR"
            n_error=$((n_error+1))
        fi
    fi

    if [ "$fetch_status" = "OK" ]; then
        rejects=$(sum_metric "coredns_forward_max_concurrent_rejects_total")
        dns_req_total=$(sum_metric "coredns_dns_requests_total")
        cache_misses=$(sum_metric "coredns_cache_misses_total")
        dns_resp_servfail=$(sum_metric_label "coredns_dns_responses_total" 'rcode="SERVFAIL"')
        proxy_conn_cache_misses=$(sum_metric "coredns_proxy_conn_cache_misses_total")
        cache_requests=$(sum_metric "coredns_cache_requests_total")
        dns_req_dur_sum=$(sum_metric "coredns_dns_request_duration_seconds_sum")
        dns_req_dur_count=$(sum_metric "coredns_dns_request_duration_seconds_count")
    else
        rejects=""
        dns_req_total=""
        cache_misses=""
        dns_resp_servfail=""
        proxy_conn_cache_misses=""
        cache_requests=""
        dns_req_dur_sum=""
        dns_req_dur_count=""
    fi

    conntrack_count=$(sudo sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo "0")
    conntrack_max=$(sudo sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "0")

    cpu_line=$(top -bn1 | grep "%Cpu")
    cpu_us=$(echo "$cpu_line" | grep -oP '[\d,\.]+(?=\s*us)' | tr ',' '.' | head -1)
    cpu_sy=$(echo "$cpu_line" | grep -oP '[\d,\.]+(?=\s*sy)' | tr ',' '.' | head -1)
    cpu_us="${cpu_us:-0}"
    cpu_sy="${cpu_sy:-0}"

    tcp_raw=$(tcp_probe)
    tcp_probe_status="${tcp_raw%%:*}"
    tcp_probe_success="${tcp_raw#*:}"

    if [ "$tcp_probe_status" = "OK" ] && [ -n "$tcp_probe_success" ]; then
        tcp_probe_attempts="$TCP_PROBE_COUNT"
        tcp_probe_loss_pct=$(awk -v ok="$tcp_probe_success" -v tot="$TCP_PROBE_COUNT" 'BEGIN { printf "%.1f", ((tot-ok)/tot)*100 }')
        tcp_loss_display="${tcp_probe_loss_pct}"
    else
        tcp_probe_attempts=""
        tcp_probe_success=""
        tcp_probe_loss_pct=""
        tcp_loss_display="n/a"
    fi

    printf "%-10s %-9s %-9s %-16s %-8s %-8s %-10s %-14s\n" \
        "$now" "$fetch_status" "${rejects:-.}" "${conntrack_count}/${conntrack_max}" "$cpu_us" "$cpu_sy" "${dns_req_total:-.}" "$tcp_loss_display"

    echo "${now_iso},${fetch_status},${rejects},${conntrack_count},${conntrack_max},${cpu_us},${cpu_sy},${dns_req_total},${cache_misses},${dns_resp_servfail},${proxy_conn_cache_misses},${cache_requests},${dns_req_dur_sum},${dns_req_dur_count},${tcp_probe_status},${tcp_probe_attempts},${tcp_probe_success},${tcp_probe_loss_pct}" >> "$CSV_FILE"

    now_ts=$(date +%s)
    elapsed=$((now_ts - START_TS))
    if [ "$elapsed" -ge "$DURATION" ]; then
        break
    fi

    sleep "$INTERVAL"
done

print_summary
