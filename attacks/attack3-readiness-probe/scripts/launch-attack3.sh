#!/usr/bin/env bash
#
# launch-attack.sh
#
# Deploys the readiness-probe flood (readiness-flood-generated.yaml) and
# waits for the malicious pods to come up. Generate the manifest first with
# manifests/generate-readiness-flood.sh.
#
# Usage: ./launch-attack.sh [manifest_path]
#   manifest_path : default ../manifests/readiness-flood-generated.yaml
#
# Cleanup: kubectl delete deployment -n attacker-ns -l attack=readiness-flood

set -euo pipefail

MANIFEST="${1:-../../manifests/attack3/readiness-flood-generated.yaml}"
NAMESPACE="attacker-ns"
LABEL="attack=readiness-flood"

if [[ ! -f "$MANIFEST" ]]; then
    echo "Manifest not found: $MANIFEST"
    echo "Generate it first: ../manifests/generate-readiness-flood.sh [count]"
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
