#!/usr/bin/env bash
#
# capture-metrics-loop.sh
#
# Capture en boucle, toutes les N secondes, les metriques cles (celles
# citees par le papier + contexte CoreDNS), dans un CSV exploitable pour
# calculer des moyennes. Chaque echantillon inclut desormais aussi une
# mesure de disponibilite TCP du control plane (perte de paquets),
# suivant le meme protocole OK/TIMEOUT/ERROR que le fetch des metriques,
# pour rester tracable dans le pipeline CSV/pandas plutot que de rester
# un test manuel ponctuel.
#
# Usage : ./capture-metrics-loop.sh [label] [intervalle_secondes] [duree_secondes]
#   label      : nom du run (ex: "before", "after") - defaut "run"
#   intervalle : defaut 20s
#   duree      : defaut 120s (2min), arret automatique
#

set -uo pipefail

SAFE_NS="safe-ns"
SAFE_POD="safe-pod"
COREDNS_SVC_IP="10.96.0.10"
COREDNS_METRICS_PORT="9153"

# Cible du sondage TCP : l'IP virtuelle du control plane telle que vue
# depuis l'interieur du cluster (VIP kubeadm), cohérente avec les tests
# ad hoc faits plus tot dans le projet (nc -z -w1 <ip> 6443).
CONTROL_PLANE_IP="10.10.10.10"
CONTROL_PLANE_PORT="6443"
TCP_PROBE_COUNT="${TCP_PROBE_COUNT:-20}"     # nombre de tentatives TCP par echantillon
TCP_PROBE_CONN_TIMEOUT="1"                   # timeout (s) de chaque tentative nc -z -w

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
    echo "ERREUR : ne lancez pas ce script avec 'sudo'."
    exit 1
fi
if ! kubectl get nodes >/dev/null 2>&1; then
    echo "ERREUR : kubectl ne parvient pas a contacter le cluster."
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

log "=== Capture en boucle demarree (label: $LABEL, intervalle: ${INTERVAL}s) ==="
log "Duree : ${DURATION}s (arret automatique, Ctrl+C possible aussi)"
log "CSV : $CSV_FILE"
echo
printf "%-10s %-9s %-9s %-16s %-8s %-8s %-10s %-14s\n" "HEURE" "STATUS" "REJECTS" "CONNTRACK" "CPU_US" "CPU_SY" "DNS_REQ" "TCP_LOSS_%"
printf "%s\n" "--------------------------------------------------------------------------------------"

n_ok=0
n_timeout=0
n_error=0

print_summary() {
    local total_attempts=$((n_ok + n_timeout + n_error))
    echo
    log "=== Capture terminee. ${total_attempts} tentative(s) au total ==="
    if [ "$total_attempts" -gt 0 ]; then
        awk -v ok="$n_ok" -v to="$n_timeout" -v err="$n_error" -v tot="$total_attempts" 'BEGIN {
            printf "  Taux de reussite (fetch metrics) : %.1f%% (%d/%d OK)\n", (ok/tot)*100, ok, tot
            printf "  Timeouts : %.1f%% (%d/%d)\n", (to/tot)*100, to, tot
            printf "  Erreurs  : %.1f%% (%d/%d)\n", (err/tot)*100, err, tot
        }'
    fi
    echo
    log "Moyennes calculees uniquement sur les echantillons OK :"
    awk -F',' '
        $2=="OK" {
            rej+=$3; ct+=$4; us+=$6; sy+=$7; req+=$8; miss+=$9; sf+=$10; n++
        }
        $15=="OK" {
            tprobe_ok+=$18; ntprobe++
        }
        END {
            if (n>0) {
                printf "  rejects_total      : moyenne=%.1f\n", rej/n
                printf "  conntrack_count    : moyenne=%.0f\n", ct/n
                printf "  CPU us+sy (%%)      : moyenne us=%.1f  sy=%.1f\n", us/n, sy/n
                printf "  dns_requests_total : moyenne=%.0f\n", req/n
                printf "  cache_misses_total : moyenne=%.0f\n", miss/n
                printf "  dns_responses SERVFAIL : moyenne=%.1f\n", sf/n
            } else {
                print "  (aucun echantillon OK sur cette capture)"
            }
            if (ntprobe>0) {
                printf "  perte de paquets TCP (control plane) : moyenne=%.1f%%\n", tprobe_ok/ntprobe
            } else {
                print "  (aucun sondage TCP OK sur cette capture)"
            }
        }' "$CSV_FILE"
    log "Detail complet : $CSV_FILE"
}

trap 'print_summary; exit 0' INT TERM

# Sonde de disponibilite TCP du control plane, executee depuis le pod
# victime (safe-pod). On envoie TCP_PROBE_COUNT tentatives nc -z -w1 en
# une seule commande (evite TCP_PROBE_COUNT invocations kubectl exec
# distinctes) et on recupere le nombre de succes. Meme classification
# OK/TIMEOUT/ERROR que le fetch des metriques : sous charge, kubectl exec
# lui-meme peut echouer/timeout, auquel cas on n'a pas de mesure (et non
# une mesure de "0% de perte" ou "100% de perte" fabriquee).
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
