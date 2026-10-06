#!/usr/bin/env bash
#
# launch-attack.sh
#
# Launches the DNS flooding attack (dns-flooder.yaml),
#
# The attack keeps running until manually deleted:
#   kubectl delete deployment dns-flood -n attacker-ns
#
# Usage: ./launch-attack.sh
#

set -uo pipefail

ATTACKER_NS="attacker-ns"
MANIFEST_DIR="$HOME/manifests/attack1"
ATTACK_MANIFEST="$MANIFEST_DIR/dns-flooder-udp.yaml"
ATTACK_DEPLOYMENT="dns-flood"

log() {
echo "[$(date '+%H:%M:%S')] $*"
}

if [ "$(id -u)" -eq 0 ]; then
echo "ERROR: do not run this script with 'sudo'. Run it as a normal user."
exit 1
fi

if ! kubectl get nodes >/dev/null 2>&1; then
echo "ERROR: kubectl cannot reach the cluster."
echo "  Check KUBECONFIG (e.g. export KUBECONFIG=/etc/kubernetes/admin.conf)"
exit 1
fi

log "Resetting the CoreDNS counter: restarting CoreDNS pods"
log "  (coredns_forward_max_concurrent_rejects_total is a Prometheus counter, it never goes"
log "   back down on its own, even long after a previous attack ended - only a"
log "   CoreDNS pod restart resets it to zero)"
kubectl delete pod -n kube-system -l k8s-app=kube-dns --wait=true --timeout=60s
log "  -> waiting for the new CoreDNS pods to be Ready..."
kubectl wait --for=condition=Ready pod -n kube-system -l k8s-app=kube-dns --timeout=60s
sleep 3
log "  -> CoreDNS restarted, the counter starts back at 0."

log "Pre-cleanup: removing any leftover from a previous attack"
if kubectl get deployment "$ATTACK_DEPLOYMENT" -n "$ATTACKER_NS" >/dev/null 2>&1; then
log "  -> deployment '$ATTACK_DEPLOYMENT' already present, deleting..."
kubectl delete deployment "$ATTACK_DEPLOYMENT" -n "$ATTACKER_NS" --wait=true --timeout=60s
kubectl wait --for=delete pod -l app=dns-flood -n "$ATTACKER_NS" --timeout=60s 2>/dev/null || true
sleep 3
fi

if [ ! -f "$ATTACK_MANIFEST" ]; then
log "ERROR: manifest not found: $ATTACK_MANIFEST"
exit 1
fi

log "Launching the attack ($ATTACK_MANIFEST)"
if ! kubectl apply -f "$ATTACK_MANIFEST"; then
log "ERROR: kubectl apply failed."
exit 1
fi

log "Waiting for pods to start (max 30s)..."
pods_found=0
for i in $(seq 1 15); do
count=$(kubectl get pods -n "$ATTACKER_NS" -l app=dns-flood --no-headers 2>/dev/null | wc -l)
if [ "$count" -gt 0 ]; then
pods_found=1
break
fi
sleep 1
done

if [ "$pods_found" -eq 0 ]; then
log "ERROR: no attack pod appeared after 15s."
exit 1
fi

if ! kubectl wait --for=condition=Ready pod -l app=dns-flood -n "$ATTACKER_NS" --timeout=90s; then
log "ERROR: attack pods did not become Ready within the allotted time."
exit 1
fi

echo
log "=== Attack running, runs indefinitely ==="
kubectl get pods -n "$ATTACKER_NS" -l app=dns-flood
echo
log "Open a second terminal and run ./watch-coredns-metrics.sh to observe the evolution."
log "To stop the attack: kubectl delete deployment $ATTACK_DEPLOYMENT -n $ATTACKER_NS"