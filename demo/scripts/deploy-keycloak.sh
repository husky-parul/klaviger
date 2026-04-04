#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-agentic-ml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying Keycloak to ${NAMESPACE} ==="

# Build the custom Keycloak image with agentic SPI (act claims + scope narrowing)
KEYCLOAK_IMAGE="keycloak-agentic-spi:latest"
SPI_DIR="${SCRIPT_DIR}/../keycloak-spi"

if [ -d "$SPI_DIR" ]; then
  echo "Building Keycloak agentic SPI image..."
  CONTAINER_TOOL="podman"
  command -v podman >/dev/null 2>&1 || CONTAINER_TOOL="docker"

  $CONTAINER_TOOL build -t "$KEYCLOAK_IMAGE" "$SPI_DIR" 2>&1 | tail -3

  # Load into Kind cluster if running locally
  if command -v kind >/dev/null 2>&1; then
    echo "Loading Keycloak image into Kind cluster..."
    if [ "$CONTAINER_TOOL" = "podman" ]; then
      $CONTAINER_TOOL save "$KEYCLOAK_IMAGE" -o /tmp/keycloak-spi.tar 2>/dev/null
      kind load image-archive /tmp/keycloak-spi.tar --name agentic-demo 2>/dev/null
      rm -f /tmp/keycloak-spi.tar
      # Tag inside the Kind node for K8s to find
      $CONTAINER_TOOL exec agentic-demo-control-plane ctr -n k8s.io images tag \
        "localhost/${KEYCLOAK_IMAGE}" "docker.io/library/${KEYCLOAK_IMAGE}" 2>/dev/null || true
    else
      kind load docker-image "$KEYCLOAK_IMAGE" --name agentic-demo 2>/dev/null
    fi
  fi
fi

# Keycloak Deployment (dev mode with persistent H2 storage)
cat <<'EOF' | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: keycloak-data
  namespace: agentic-ml
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: agentic-ml
  labels:
    app: keycloak
spec:
  selector:
    app: keycloak
  ports:
  - name: http
    port: 80
    targetPort: 8080
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: agentic-ml
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
      - name: keycloak
        image: keycloak-agentic-spi:latest
        imagePullPolicy: Never
        args: ["start-dev"]
        ports:
        - containerPort: 8080
        env:
        - name: KC_HOSTNAME
          value: "keycloak.agentic-ml.svc"
        - name: KC_HOSTNAME_STRICT
          value: "true"
        - name: KC_HTTP_ENABLED
          value: "true"
        - name: KC_PROXY_HEADERS
          value: "xforwarded"
        - name: KC_BOOTSTRAP_ADMIN_USERNAME
          value: "admin"
        - name: KC_BOOTSTRAP_ADMIN_PASSWORD
          value: "admin"
        # Enable federated JWT auth, K8s SA support, and preview features (incl token-exchange-standard)
        - name: KC_FEATURES
          value: "client-auth-federated,kubernetes-service-accounts,token-exchange-standard"
        # Trust the K8s API server CA for validating SA tokens
        - name: KC_TRUSTSTORE_PATHS
          value: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        # Persistent H2 database
        - name: KC_DB
          value: "dev-file"
        volumeMounts:
        - name: data
          mountPath: /opt/keycloak/data
        resources:
          requests: { memory: "512Mi", cpu: "250m" }
          limits: { memory: "1Gi", cpu: "1000m" }
        readinessProbe:
          httpGet:
            path: /realms/master
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: keycloak-data
EOF

echo ""
echo "Waiting for Keycloak to be ready (this may take 1-2 minutes)..."
kubectl -n agentic-ml wait --for=condition=ready pod -l app=keycloak --timeout=180s 2>/dev/null || {
  echo "Keycloak not ready yet. Check: kubectl -n agentic-ml logs -l app=keycloak"
  exit 1
}

# Check if demo realm already exists (persistent storage)
KC_POD=$(kubectl -n agentic-ml get pods -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
REALM_EXISTS=$(kubectl -n agentic-ml exec "$KC_POD" -- /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password admin 2>&1 && \
  kubectl -n agentic-ml exec "$KC_POD" -- /opt/keycloak/bin/kcadm.sh get realms/demo 2>&1 | grep -c '"realm"' || echo "0")

if [ "$REALM_EXISTS" = "0" ]; then
  echo ""
  echo "Configuring Keycloak realm and clients..."
  "${SCRIPT_DIR}/configure-keycloak.sh"
else
  echo ""
  echo "Demo realm already exists (persistent storage). Skipping configuration."
fi

echo ""
echo "=== Keycloak deployed and configured ==="
echo "Admin console: kubectl -n agentic-ml port-forward svc/keycloak 9080:80"
echo "               http://localhost:9080 (admin/admin)"
