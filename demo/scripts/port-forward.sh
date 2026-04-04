#!/usr/bin/env bash
set -euo pipefail

echo "=== Starting port-forwards for demo ==="
echo ""

# Kill any existing port-forwards
pkill -f "kubectl.*port-forward" 2>/dev/null || true
sleep 1

# Classic pipeline
echo "Classic orchestrator -> localhost:8081"
kubectl -n classic-ml port-forward svc/orchestrator 8081:80 &>/dev/null &

# Agentic pipeline
echo "Agentic orchestrator -> localhost:8082"
kubectl -n agentic-ml port-forward svc/orchestrator 8082:80 &>/dev/null &

# Keycloak admin
echo "Keycloak admin       -> localhost:9080"
kubectl -n agentic-ml port-forward svc/keycloak 9080:80 &>/dev/null &

echo ""
echo "=== Port-forwards active ==="
echo ""
echo "Endpoints:"
echo "  Classic orchestrator:  http://localhost:8081"
echo "  Agentic orchestrator:  http://localhost:8082"
echo "  Keycloak admin:        http://localhost:9080 (admin/admin)"
echo ""
echo "Dashboard: open demo/dashboard/index.html in a browser"
echo ""
echo "Press Ctrl+C to stop all port-forwards"

# Wait for interrupt
trap 'echo ""; echo "Stopping port-forwards..."; pkill -f "kubectl.*port-forward" 2>/dev/null; exit 0' INT TERM
wait
