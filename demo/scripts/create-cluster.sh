#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-agentic-demo}"

echo "=== Creating Kind cluster: ${CLUSTER_NAME} ==="

# Check prerequisites
for cmd in kind kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not installed."
    exit 1
  fi
done

# Detect container runtime (podman or docker)
if command -v podman &>/dev/null; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
  echo "Using podman as container runtime"
  # Ensure podman socket is active
  systemctl --user start podman.socket 2>/dev/null || true
elif command -v docker &>/dev/null; then
  echo "Using docker as container runtime"
else
  echo "ERROR: podman or docker is required but neither is installed."
  exit 1
fi

# Delete existing cluster if it exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster ${CLUSTER_NAME} already exists. Deleting..."
  kind delete cluster --name "${CLUSTER_NAME}"
fi

# Create cluster with extra port mappings for dashboard access
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  # Dashboard access
  - containerPort: 30080
    hostPort: 8080
    protocol: TCP
  # Classic pipeline
  - containerPort: 30081
    hostPort: 8081
    protocol: TCP
  # Agentic pipeline
  - containerPort: 30082
    hostPort: 8082
    protocol: TCP
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        # Enable projected service account tokens for OIDC audience
        service-account-issuer: "https://kubernetes.default.svc.cluster.local"
        service-account-key-file: /etc/kubernetes/pki/sa.pub
        service-account-signing-key-file: /etc/kubernetes/pki/sa.key
        api-audiences: "https://kubernetes.default.svc.cluster.local,http://keycloak.agentic-ml.svc/realms/demo"
EOF

echo ""
echo "=== Cluster ${CLUSTER_NAME} created ==="
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo ""
echo "Next: run ./build-images.sh to build and load demo images."
