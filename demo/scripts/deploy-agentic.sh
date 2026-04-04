#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../k8s/agentic"

echo "=== Deploying Agentic ML Pipeline (agentic-ml namespace) ==="

# Apply manifests in order
kubectl apply -f "${K8S_DIR}/namespace.yaml"
kubectl apply -f "${K8S_DIR}/rbac.yaml"
kubectl apply -f "${K8S_DIR}/keycloak-realm.yaml"

# Deploy Keycloak first (agents depend on it)
"${SCRIPT_DIR}/deploy-keycloak.sh" agentic-ml

# Apply agent configs and deployments
kubectl apply -f "${K8S_DIR}/configmap.yaml"
kubectl apply -f "${K8S_DIR}/deployment.yaml"

echo ""
echo "Waiting for agent pods to be ready..."
kubectl -n agentic-ml wait --for=condition=ready pod -l app=ml-agent --timeout=120s 2>/dev/null || true
kubectl -n agentic-ml wait --for=condition=ready pod -l app=model-registry --timeout=120s 2>/dev/null || true

echo ""
echo "=== Agentic ML Pipeline Status ==="
kubectl -n agentic-ml get pods -o wide
echo ""
kubectl -n agentic-ml get svc

echo ""
echo "=== Agentic pipeline deployed ==="
echo ""
echo "To test: kubectl -n agentic-ml port-forward svc/orchestrator 8082:80"
echo "Then:    curl -s http://localhost:8082/api/info | jq ."
