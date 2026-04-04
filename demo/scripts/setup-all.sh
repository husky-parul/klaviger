#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "  Agentic IAM Demo - Full Setup"
echo "  PyTorch Conference Europe 2026"
echo "============================================"
echo ""

cd "${SCRIPT_DIR}"

echo "[1/5] Creating Kind cluster..."
./create-cluster.sh
echo ""

echo "[2/5] Building Docker images..."
./build-images.sh
echo ""

echo "[3/5] Deploying Classic ML Pipeline..."
./deploy-classic.sh
echo ""

echo "[4/5] Deploying Agentic ML Pipeline (with Keycloak)..."
./deploy-agentic.sh
echo ""

echo "[5/5] Verifying deployment..."
./verify.sh
echo ""

echo "============================================"
echo "  Setup complete!"
echo ""
echo "  Run ./port-forward.sh to start demo"
echo "  Run ./test-demo.sh to verify scenarios"
echo "============================================"
