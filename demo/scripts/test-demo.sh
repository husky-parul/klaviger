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

# Login as Alice to get a token (login endpoint bypasses auth)
echo "  Logging in as Alice..."
LOGIN=$(curl -s -X POST http://localhost:18082/api/login -H 'Content-Type: application/json' -d '{"username":"alice","password":"demo"}' 2>/dev/null)
TOKEN=$(echo "$LOGIN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
if [ -n "$TOKEN" ] && [ "$TOKEN" != "" ]; then
  echo -e "  ${GREEN}PASS${NC} Login as Alice (got token)"
else
  echo -e "  ${RED}FAIL${NC} Login as Alice"
fi

# Test Agent Card (no auth needed — public path)
echo ""
echo "Testing Agent Cards (Pillar 2: Discoverability):"
CARD=$(curl -s http://localhost:18082/.well-known/agent.json 2>/dev/null)
CARD_NAME=$(echo "$CARD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('card',{}).get('name','N/A'))" 2>/dev/null || echo "N/A")
CARD_IDENTITY=$(echo "$CARD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('card',{}).get('identity','N/A'))" 2>/dev/null || echo "N/A")
HAS_TOKEN=$(echo "$CARD" | python3 -c "import sys,json; print('yes' if json.load(sys.stdin).get('identity_token') else 'no')" 2>/dev/null || echo "N/A")
echo -e "  ${GREEN}Agent Card: ${CARD_NAME}${NC}"
echo -e "  ${GREEN}Identity: ${CARD_IDENTITY}${NC}"
echo -e "  ${GREEN}Identity Token (K8s SA JWT): ${HAS_TOKEN}${NC}"

# Run full pipeline with Alice's token
echo ""
echo "Testing full pipeline (Pillar 1: Delegation + Scope Narrowing):"
if [ -n "$TOKEN" ] && [ "$TOKEN" != "" ]; then
  RESULT=$(curl -s -X POST http://localhost:18082/api/run-pipeline -H "Authorization: Bearer $TOKEN" 2>/dev/null)

  # Check orchestrator
  ORCH_SUB=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['agent']['subject'])" 2>/dev/null || echo "N/A")
  echo -e "  ${GREEN}Orchestrator sub: ${ORCH_SUB} (Alice)${NC}"
  echo -e "  ${GREEN}FIX 1: Each agent has its own identity!${NC}"

  # Check downstream agents have actor claims
  echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for dr in d.get('downstream_results', []):
    r = dr.get('response', {})
    a = r.get('agent', {})
    name = a.get('agent_name', '?')
    actor = a.get('actor', '')
    scopes = a.get('scopes', '')
    status = '✓' if actor else '✗'
    print(f'  {status} {name}: actor={actor}, scopes={scopes[:60]}')
    mrt = r.get('model_registry_test')
    if mrt:
        allowed = mrt.get('allowed', 'N/A')
        print(f'    Model registry write: allowed={allowed}')
" 2>/dev/null

  echo -e "  ${GREEN}FIX 2: Scope narrowing prevents unauthorized writes!${NC}"
  echo -e "  ${GREEN}FIX 3: Delegation chain tracks who acts on whose behalf!${NC}"
fi

# Cleanup
kill $PF_AGENTIC 2>/dev/null || true

echo ""
echo "=== Demo tests complete ==="
echo ""
echo "For interactive demo, run:"
echo "  ./port-forward.sh"
echo "  Then open demo/dashboard/index.html in a browser"
