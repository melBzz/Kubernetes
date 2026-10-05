#!/usr/bin/env bash
#
# generate-readiness-flood.sh
#
# Generates COUNT separate Deployments (one pod, one ReplicaSet, one
# Deployment each), each with a readiness probe that flips every second,
# matching the paper's local setup (100 malicious containers, each in its
# own pod/replicaset/deployment, §4.4).
#
# Usage: ./generate-readiness-flood.sh [count]
#   count : number of Deployments to generate, default 100
#
# Output: readiness-flood-generated.yaml, next to this script.

set -euo pipefail

COUNT="${1:-100}"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_FILE="$OUT_DIR/readiness-flood-generated.yaml"

> "$OUT_FILE"

for i in $(seq 1 "$COUNT"); do
    cat >> "$OUT_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: readiness-flood-${i}
  namespace: attacker-ns
  labels:
    attack: readiness-flood
spec:
  replicas: 1
  selector:
    matchLabels:
      app: readiness-flood-${i}
  template:
    metadata:
      labels:
        app: readiness-flood-${i}
        attack: readiness-flood
    spec:
      nodeName: k8s-w1
      containers:
      - name: flooder
        image: busybox:1.36
        command: ["sleep", "infinity"]
        readinessProbe:
          exec:
            command: ["sh", "-c", "test \$(( \$(date +%s) % 2 )) -eq 0"]
          periodSeconds: 1
          timeoutSeconds: 1
          failureThreshold: 1
          successThreshold: 1
        resources:
          requests:
            cpu: "10m"
            memory: "16Mi"
          limits:
            cpu: "50m"
            memory: "32Mi"
        securityContext:
          allowPrivilegeEscalation: false
          privileged: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 1000
          seccompProfile:
            type: RuntimeDefault
          capabilities:
            drop: ["ALL"]
---
EOF
done

echo "Generated ${COUNT} Deployments -> ${OUT_FILE}"
echo "Apply with:  kubectl apply -f ${OUT_FILE}"
echo "Remove with: kubectl delete deployment -n attacker-ns -l attack=readiness-flood"
