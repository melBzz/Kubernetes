#!/usr/bin/env bash
#
# launch-attack4.sh
#
# Deploys the endpoints flood (endpoints-flood-generated.yaml, 100
# Deployments plus the Service that groups them) and waits for the
# malicious pods to come up. Generate the manifest first with
# manifests/generate-endpoints-flood.sh.
#
# Usage: ./launch-attack.sh [manifest_path]
#   manifest_path : default ../manifests/endpoints-flood-generated.yaml
#
# Cleanup: kubectl delete deployment,service -n attacker-ns -l attack=endpoints-flood

set -euo pipefail

MANIFEST="${1:-../../manifests/attack4/endpoints-flood-generated.yaml}"
NAMESPACE="attacker-ns"
LABEL="attack=endpoints-flood"

if [[ ! -f "$MANIFEST" ]]; then
    echo "Manifest not found: $MANIFEST"
    echo "Generate it first: ../../manifests/attack4/generate-endpoints-flood.sh [count]"
    exit 1
fi

kubectl apply -f "$MANIFEST"

echo "Waiting for pods to be created..."
sleep 5

TOTAL=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL" --no-headers 2>/dev/null | wc -l)
echo "Pods matching $LABEL: $TOTAL"

kubectl wait --for=condition=Ready pod -n "$NAMESPACE" -l "$LABEL" --timeout=120s || true

echo "Current status:"
kubectl get pods -n "$NAMESPACE" -l "$LABEL" -o wide
echo
kubectl get endpoints -n "$NAMESPACE" endpoints-flood-svc
