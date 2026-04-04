#!/usr/bin/env bash
set -euo pipefail

echo "=== Demo Environment Verification ==="
echo ""

# Check Kind cluster
echo "--- Kind Cluster ---"
if kind get clusters 2>/dev/null | grep -q "agentic-demo"; then
  echo "  Cluster: agentic-demo [OK]"
else
  echo "  Cluster: agentic-demo [NOT FOUND]"
  echo "  Run: ./create-cluster.sh"
  exit 1
fi

echo ""
echo "--- Classic ML Pipeline (classic-ml) ---"
if kubectl get ns classic-ml &>/dev/null; then
  echo "  Namespace: classic-ml [OK]"
  echo "  Pods:"
  kubectl -n classic-ml get pods --no-headers 2>/dev/null | while read -r line; do
    echo "    $line"
  done
  READY=$(kubectl -n classic-ml get pods --no-headers 2>/dev/null | grep -c "Running" || true)
  TOTAL=$(kubectl -n classic-ml get pods --no-headers 2>/dev/null | wc -l || true)
  echo "  Ready: ${READY}/${TOTAL}"
else
  echo "  Namespace: classic-ml [NOT DEPLOYED]"
  echo "  Run: ./deploy-classic.sh"
fi

echo ""
echo "--- Agentic ML Pipeline (agentic-ml) ---"
if kubectl get ns agentic-ml &>/dev/null; then
  echo "  Namespace: agentic-ml [OK]"
  echo "  Pods:"
  kubectl -n agentic-ml get pods --no-headers 2>/dev/null | while read -r line; do
    echo "    $line"
  done
  READY=$(kubectl -n agentic-ml get pods --no-headers 2>/dev/null | grep -c "Running" || true)
  TOTAL=$(kubectl -n agentic-ml get pods --no-headers 2>/dev/null | wc -l || true)
  echo "  Ready: ${READY}/${TOTAL}"

  # Check Keycloak specifically
  echo ""
  echo "  Keycloak:"
  KC_STATUS=$(kubectl -n agentic-ml get pod -l app=keycloak --no-headers 2>/dev/null | awk '{print $3}' || echo "NOT FOUND")
  echo "    Status: ${KC_STATUS}"
else
  echo "  Namespace: agentic-ml [NOT DEPLOYED]"
  echo "  Run: ./deploy-agentic.sh"
fi

echo ""
echo "--- Images ---"
CTR=$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || echo "")
for img in demo-ml-agent demo-model-registry; do
  if [ -n "$CTR" ] && $CTR image inspect "${img}:latest" &>/dev/null; then
    echo "  ${img}:latest [OK]"
  else
    echo "  ${img}:latest [NOT BUILT]"
  fi
done

echo ""
echo "=== Verification complete ==="
