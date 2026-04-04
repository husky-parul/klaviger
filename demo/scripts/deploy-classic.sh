#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../k8s/classic"

echo "=== Deploying Classic ML Pipeline (classic-ml namespace) ==="

# Apply manifests in order
kubectl apply -f "${K8S_DIR}/namespace.yaml"
kubectl apply -f "${K8S_DIR}/rbac.yaml"
kubectl apply -f "${K8S_DIR}/deployment.yaml"

echo ""
echo "Waiting for pods to be ready..."
kubectl -n classic-ml wait --for=condition=ready pod --all --timeout=120s 2>/dev/null || true

echo ""
echo "=== Classic ML Pipeline Status ==="
kubectl -n classic-ml get pods -o wide
echo ""
kubectl -n classic-ml get svc

echo ""
echo "=== Classic pipeline deployed ==="
echo ""
echo "To test: kubectl -n classic-ml port-forward svc/orchestrator 8081:80"
echo "Then:    curl -s http://localhost:8081/api/info | jq ."
