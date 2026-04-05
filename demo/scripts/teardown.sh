#!/usr/bin/env bash
set -euo pipefail

# Ensure kind can find podman-based clusters
if command -v podman >/dev/null 2>&1; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
fi

CLUSTER_NAME="${CLUSTER_NAME:-agentic-demo}"

echo "=== Tearing down demo environment ==="

# Kill port-forwards
pkill -f "kubectl.*port-forward" 2>/dev/null || true

# Delete the Kind cluster
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Deleting Kind cluster: ${CLUSTER_NAME}..."
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "Cluster deleted."
else
  echo "Cluster ${CLUSTER_NAME} not found."
fi

# Optionally clean up images
echo ""
echo "Docker images (not removed):"
echo "  docker rmi demo-ml-agent:latest demo-model-registry:latest"

echo ""
echo "=== Teardown complete ==="
