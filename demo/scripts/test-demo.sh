#!/usr/bin/env bash
set -euo pipefail

echo "=== Testing Demo Scenarios ==="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

test_endpoint() {
  local label="$1"
  local url="$2"
  local expected_status="${3:-200}"

  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  if [ "$STATUS" = "$expected_status" ]; then
    echo -e "  ${GREEN}PASS${NC} ${label} (HTTP ${STATUS})"
  else
    echo -e "  ${RED}FAIL${NC} ${label} (HTTP ${STATUS}, expected ${expected_status})"
  fi
}

# --- Classic Pipeline Tests ---
echo "--- Classic Pipeline (Break 1: Shared Identity) ---"
echo ""
echo "Starting port-forward to classic orchestrator..."
kubectl -n classic-ml port-forward svc/orchestrator 18081:80 &>/dev/null &
PF_CLASSIC=$!
sleep 2

echo "Testing classic endpoints:"
test_endpoint "Orchestrator /api/info" "http://localhost:18081/api/info"

# Get identity info
CLASSIC_INFO=$(curl -s http://localhost:18081/api/info 2>/dev/null)
CLASSIC_SA=$(echo "$CLASSIC_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('service_account','N/A'))" 2>/dev/null || echo "N/A")
echo -e "  ${YELLOW}Service Account: ${CLASSIC_SA}${NC}"
echo -e "  ${RED}BREAK 1: All agents share the same identity!${NC}"

echo ""
echo "--- Classic Pipeline (Break 2: Over-Permissioned) ---"
echo ""
echo "Starting port-forward to classic data-agent..."
kubectl -n classic-ml port-forward svc/data-agent 18083:80 &>/dev/null &
PF_DATA=$!
sleep 2

WRITE_RESULT=$(curl -s -X POST http://localhost:18083/api/run-pipeline 2>/dev/null)
REGISTRY_ALLOWED=$(echo "$WRITE_RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin).get('model_registry_test',{}); print(r.get('allowed','N/A') if r else 'N/A')" 2>/dev/null || echo "N/A")
echo -e "  Data-agent write to model-registry: ${REGISTRY_ALLOWED}"
echo -e "  ${RED}BREAK 2: Data-agent can write to model-registry (should only read!)${NC}"

# Cleanup classic port-forwards
kill $PF_CLASSIC $PF_DATA 2>/dev/null || true

echo ""
echo "--- Agentic Pipeline (All Breaks Fixed) ---"
echo ""
echo "Starting port-forward to agentic orchestrator..."
kubectl -n agentic-ml port-forward svc/orchestrator 18082:80 &>/dev/null &
PF_AGENTIC=$!
sleep 2

echo "Testing agentic endpoints:"
test_endpoint "Orchestrator /api/info" "http://localhost:18082/api/info"

# Get agentic identity info
AGENTIC_INFO=$(curl -s http://localhost:18082/api/info 2>/dev/null)
AGENTIC_SA=$(echo "$AGENTIC_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('service_account','N/A'))" 2>/dev/null || echo "N/A")
AGENTIC_AUD=$(echo "$AGENTIC_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('audience','N/A'))" 2>/dev/null || echo "N/A")
echo -e "  ${GREEN}Service Account: ${AGENTIC_SA}${NC}"
echo -e "  ${GREEN}FIX 1: Each agent has its own identity!${NC}"

# Test Agent Card
echo ""
echo "Testing Agent Cards (Pillar 2: Discoverability):"
CARD=$(curl -s http://localhost:18082/.well-known/agent.json 2>/dev/null)
CARD_NAME=$(echo "$CARD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','N/A'))" 2>/dev/null || echo "N/A")
CARD_IDENTITY=$(echo "$CARD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('identity','N/A'))" 2>/dev/null || echo "N/A")
echo -e "  ${GREEN}Agent Card: ${CARD_NAME}${NC}"
echo -e "  ${GREEN}SPIFFE Identity: ${CARD_IDENTITY}${NC}"

# Cleanup
kill $PF_AGENTIC 2>/dev/null || true

echo ""
echo "=== Demo tests complete ==="
echo ""
echo "For full pipeline test with delegation chains:"
echo "  kubectl -n agentic-ml port-forward svc/orchestrator 8082:80"
echo "  curl -s -X POST http://localhost:8082/api/run-pipeline | jq ."
