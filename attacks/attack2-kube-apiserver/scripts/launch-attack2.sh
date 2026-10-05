#!/usr/bin/env bash
#
# launch-attack.sh
#
# Launches only the kube-apiserver flooding attack (apiserver-flood.yaml),
# with no metrics collection. 
#
# The attack keeps running indefinitely until manually deleted:
#   kubectl delete deployment apiserver-flood -n attacker-ns
#
# Usage: ./launch-attack22.sh
#
set -uo pipefail

ATTACKER_NS="attacker-ns"
MANIFEST_DIR="$HOME/manifests/attack2"
ATTACK_MANIFEST="$MANIFEST_DIR/apiserver-flood.yaml"
ATTACK_DEPLOYMENT="apiserver-flood"

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

log "Pre-cleanup: removing any leftover deployment from a previous run"
if kubectl get deployment "$ATTACK_DEPLOYMENT" -n "$ATTACKER_NS" >/dev/null 2>&1; then
    log "  -> deployment '$ATTACK_DEPLOYMENT' already present, deleting..."
    kubectl delete deployment "$ATTACK_DEPLOYMENT" -n "$ATTACKER_NS" --wait=true --timeout=60s
    kubectl wait --for=delete pod -l app=apiserver-flood -n "$ATTACKER_NS" --timeout=60s 2>/dev/null || true
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
    count=$(kubectl get pods -n "$ATTACKER_NS" -l app=apiserver-flood --no-headers 2>/dev/null | wc -l)
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

if ! kubectl wait --for=condition=Ready pod -l app=apiserver-flood -n "$ATTACKER_NS" --timeout=90s; then
    log "ERROR: attack pods did not become Ready within the time limit."
    exit 1
fi

echo
log "=== Attack running, continues indefinitely ==="
kubectl get pods -n "$ATTACKER_NS" -l app=apiserver-flood
echo
log "Open a second terminal and run ./capture-metrics-loop-attack2.sh to observe the evolution."
log "To stop the attack: kubectl delete deployment $ATTACK_DEPLOYMENT -n $ATTACKER_NS"
