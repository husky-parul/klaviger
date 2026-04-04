#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-agentic-demo}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Building demo container images ==="

# Detect container runtime
if command -v podman &>/dev/null; then
  CTR=podman
  export KIND_EXPERIMENTAL_PROVIDER=podman
else
  CTR=docker
fi
echo "Using ${CTR} as container runtime"

# Build agent image
echo "Building demo-ml-agent..."
${CTR} build -t demo-ml-agent:latest "${DEMO_DIR}/agent"

# Build model-registry image
echo "Building demo-model-registry..."
${CTR} build -t demo-model-registry:latest "${DEMO_DIR}/model-registry"

echo ""
echo "=== Loading images into Kind cluster ==="
if [ "${CTR}" = "podman" ]; then
  # Podman + Kind: use image-archive method (kind load docker-image doesn't work with podman)
  NODE="${CLUSTER_NAME}-control-plane"
  for img in demo-ml-agent demo-model-registry; do
    echo "Saving and loading ${img}..."
    ${CTR} save "${img}:latest" -o "/tmp/${img}.tar"
    kind load image-archive "/tmp/${img}.tar" --name "${CLUSTER_NAME}"
    rm -f "/tmp/${img}.tar"
    # Podman loads as localhost/<name>; K8s manifests expect <name> — add docker.io alias
    ${CTR} exec "${NODE}" ctr -n k8s.io images tag "localhost/${img}:latest" "docker.io/library/${img}:latest" 2>/dev/null || true
  done
else
  kind load docker-image demo-ml-agent:latest --name "${CLUSTER_NAME}"
  kind load docker-image demo-model-registry:latest --name "${CLUSTER_NAME}"
fi

echo ""
echo "=== Images ready ==="
echo "  - demo-ml-agent:latest"
echo "  - demo-model-registry:latest"
echo ""
echo "Next: run ./deploy-classic.sh and/or ./deploy-agentic.sh"
