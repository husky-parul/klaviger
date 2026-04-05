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

# Build Klaviger sidecar proxy
REPO_ROOT="$(cd "${DEMO_DIR}/.." && pwd)"
echo "Building klaviger..."
if [ "${CTR}" = "podman" ]; then
  # Build Go binary in a container (Go may not be installed on the host)
  ${CTR} run --rm --userns=keep-id -v "${REPO_ROOT}":/src:Z -w /src golang:1.24 \
    go build -o /src/klaviger-bin ./cmd/klaviger/
  # Build minimal runtime image
  ${CTR} build -f - -t klaviger:latest "${REPO_ROOT}" <<'DOCKERFILE'
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
RUN microdnf install -y ca-certificates && microdnf clean all
COPY klaviger-bin /usr/local/bin/klaviger
RUN chmod +x /usr/local/bin/klaviger
USER 1001
EXPOSE 8180 8190
ENTRYPOINT ["/usr/local/bin/klaviger"]
CMD ["--config", "/etc/klaviger/config.yaml"]
DOCKERFILE
  rm -f "${REPO_ROOT}/klaviger-bin"
else
  ${CTR} build -t klaviger:latest -f "${REPO_ROOT}/deployments/Dockerfile" "${REPO_ROOT}"
fi

echo ""
echo "=== Loading images into Kind cluster ==="
if [ "${CTR}" = "podman" ]; then
  # Podman + Kind: use image-archive method (kind load docker-image doesn't work with podman)
  NODE="${CLUSTER_NAME}-control-plane"
  for img in demo-ml-agent demo-model-registry klaviger; do
    echo "Saving and loading ${img}..."
    rm -f "/tmp/${img}.tar"
    ${CTR} save "${img}:latest" -o "/tmp/${img}.tar"
    # Load directly into Kind node's containerd (kind load hangs with some podman versions)
    ${CTR} exec -i "${NODE}" ctr -n k8s.io images import - < "/tmp/${img}.tar"
    rm -f "/tmp/${img}.tar"
    # Podman loads as localhost/<name>; K8s manifests expect <name> — add docker.io alias
    ${CTR} exec "${NODE}" ctr -n k8s.io images tag "localhost/${img}:latest" "docker.io/library/${img}:latest" 2>/dev/null || true
  done
else
  kind load docker-image demo-ml-agent:latest --name "${CLUSTER_NAME}"
  kind load docker-image demo-model-registry:latest --name "${CLUSTER_NAME}"
  kind load docker-image klaviger:latest --name "${CLUSTER_NAME}"
fi

echo ""
echo "=== Images ready ==="
echo "  - demo-ml-agent:latest"
echo "  - demo-model-registry:latest"
echo "  - klaviger:latest"
echo ""
echo "Note: keycloak-agentic-spi is built by deploy-keycloak.sh"
echo ""
echo "Next: run ./deploy-classic.sh and/or ./deploy-agentic.sh"
