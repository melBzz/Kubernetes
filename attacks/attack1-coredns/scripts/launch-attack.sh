#!/usr/bin/env bash
#
# launch-attack.sh
#
# Lance uniquement l'attaque DNS flooding (dns-flooder.yaml), sans aucune
# collecte de métriques. À utiliser dans un premier terminal, en parallèle
# de watch-coredns-metrics.sh lancé dans un second terminal pour observer
# l'évolution des métriques en temps réel pendant que l'attaque tourne.
#
# L'attaque continue de tourner indéfiniment jusqu'à suppression manuelle :
#   kubectl delete deployment dns-flood -n attacker-ns
#
# Usage : ./launch-attack.sh
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
    echo "ERREUR : ne lancez pas ce script avec 'sudo'. Lancez-le en utilisateur normal."
    exit 1
fi

if ! kubectl get nodes >/dev/null 2>&1; then
    echo "ERREUR : kubectl ne parvient pas à contacter le cluster."
    echo "  Vérifiez KUBECONFIG (ex: export KUBECONFIG=/etc/kubernetes/admin.conf)"
    exit 1
fi

log "Réinitialisation du compteur CoreDNS : redémarrage des pods CoreDNS"
log "  (coredns_forward_max_concurrent_rejects_total est un counter Prometheus, il ne redescend"
log "   jamais tout seul, même longtemps après la fin d'une attaque précédente - seul un"
log "   redémarrage du pod CoreDNS le remet à zéro)"
kubectl delete pod -n kube-system -l k8s-app=kube-dns --wait=true --timeout=60s
log "  -> attente que les nouveaux pods CoreDNS soient Ready..."
kubectl wait --for=condition=Ready pod -n kube-system -l k8s-app=kube-dns --timeout=60s
sleep 3
log "  -> CoreDNS redémarré, le compteur repart de 0."

log "Nettoyage préalable : suppression d'un éventuel résidu d'attaque précédente"
if kubectl get deployment "$ATTACK_DEPLOYMENT" -n "$ATTACKER_NS" >/dev/null 2>&1; then
    log "  -> deployment '$ATTACK_DEPLOYMENT' déjà présent, suppression..."
    kubectl delete deployment "$ATTACK_DEPLOYMENT" -n "$ATTACKER_NS" --wait=true --timeout=60s
    kubectl wait --for=delete pod -l app=dns-flood -n "$ATTACKER_NS" --timeout=60s 2>/dev/null || true
    sleep 3
fi

if [ ! -f "$ATTACK_MANIFEST" ]; then
    log "ERREUR : manifest introuvable : $ATTACK_MANIFEST"
    exit 1
fi

log "Lancement de l'attaque ($ATTACK_MANIFEST)"
if ! kubectl apply -f "$ATTACK_MANIFEST"; then
    log "ERREUR : kubectl apply a échoué."
    exit 1
fi

log "Attente que les pods démarrent (max 30s)..."
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
    log "ERREUR : aucun pod d'attaque n'est apparu après 15s."
    exit 1
fi

if ! kubectl wait --for=condition=Ready pod -l app=dns-flood -n "$ATTACKER_NS" --timeout=90s; then
    log "ERREUR : les pods d'attaque ne sont pas devenus Ready dans le délai imparti."
    exit 1
fi

echo
log "=== Attaque en cours, tourne indéfiniment ==="
kubectl get pods -n "$ATTACKER_NS" -l app=dns-flood
echo
log "Ouvrez un second terminal et lancez ./watch-coredns-metrics.sh pour observer l'évolution."
log "Pour arrêter l'attaque : kubectl delete deployment $ATTACK_DEPLOYMENT -n $ATTACKER_NS"
