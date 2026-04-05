#!/bin/bash -e
# Configure Keycloak for the agentic IAM demo
# Based on the Klaviger oauth-token-exchange example
#
# Uses kcadm for basic object creation (realms, clients, users, scopes)
# Uses REST API via python for operations where kcadm silently fails:
#   - Setting client attributes (kcadm -b broken on KC 26.5.2)
#   - Assigning audience scopes to clients

KC_POD=$(kubectl -n agentic-ml get pods -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
KCADMIN="kubectl -n agentic-ml exec $KC_POD -- /opt/keycloak/bin/kcadm.sh"

echo "=== Configuring Keycloak for Agentic IAM Demo ==="
echo "Pod: $KC_POD"

# Login to admin CLI
$KCADMIN config credentials --server http://localhost:8080 --realm master --user admin --password admin

# Create demo realm
echo "Creating demo realm..."
$KCADMIN create realms -s realm=demo -s enabled=true -s verifyEmail=false 2>/dev/null || echo "  (realm may already exist)"

# Create Kubernetes identity provider (for federated JWT auth with K8s SA tokens)
echo "Creating Kubernetes identity provider..."
$KCADMIN create identity-provider/instances -r demo \
  -s alias=kubernetes \
  -s providerId=kubernetes \
  -s config='{"issuer": "https://kubernetes.default.svc.cluster.local"}' 2>/dev/null || echo "  (idp may already exist)"

# Create client scopes for agent capabilities
echo "Creating client scopes..."
SCOPES=("read:features" "write:model-registry" "provision:gpu" "read:test-data" "write:eval-reports" "deploy:staging")

for scope in "${SCOPES[@]}"; do
  $KCADMIN create client-scopes -r demo -s "name=${scope}" -s protocol="openid-connect" 2>/dev/null || true
  echo "  ${scope}"
done

# Create audience client scopes (aud:agent-name) with audience mappers
echo "Creating audience scopes..."
AGENTS=("orchestrator" "data-agent" "training-agent" "eval-agent" "deploy-agent" "model-registry")
for agent in "${AGENTS[@]}"; do
  AUD_SCOPE_ID=$($KCADMIN create client-scopes -r demo -s "name=aud:${agent}" -s protocol="openid-connect" -i 2>/dev/null || echo "")
  if [ -n "$AUD_SCOPE_ID" ]; then
    $KCADMIN create "client-scopes/${AUD_SCOPE_ID}/protocol-mappers/models" -r demo \
      -s "name=${agent}-audience-mapper" \
      -s protocol="openid-connect" \
      -s protocolMapper="oidc-audience-mapper" \
      -s "config={\"included.client.audience\":\"${agent}\", \"access.token.claim\":\"true\"}" 2>/dev/null || true
  fi
  echo "  aud:${agent}"
done

# Create agent clients with federated JWT auth (K8s SA tokens)
echo "Creating agent clients..."
for agent in "${AGENTS[@]}"; do
  echo "  Creating client: ${agent}"
  $KCADMIN create clients -r demo \
    -s "clientId=${agent}" \
    -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=true \
    -s "clientAuthenticatorType=federated-jwt" \
    2>/dev/null || echo "    (client may already exist)"
done

# Create a demo user and public client for the dashboard
echo "Creating demo user and dashboard client..."
$KCADMIN create clients -r demo \
  -s clientId=demo-dashboard \
  -s publicClient=true \
  -s directAccessGrantsEnabled=true \
  -s enabled=true 2>/dev/null || echo "  (dashboard client may already exist)"

$KCADMIN create users -r demo \
  -s username=alice \
  -s enabled=true \
  -s firstName=Alice \
  -s lastName=MLEngineer \
  -s "email=alice@example.com" \
  -s emailVerified=true \
  -s 'requiredActions=[]' 2>/dev/null || echo "  (user may already exist)"

$KCADMIN set-password -r demo --username alice --new-password demo 2>/dev/null || true

# === REST API section ===
# kcadm -b silently fails on KC 26.5.2 for setting attributes.
# Use REST API via kubectl port-forward + curl from the host.
echo ""
echo "Configuring client attributes and scope assignments via REST API..."

# Port-forward Keycloak to a local port for REST API calls
KC_LOCAL_PORT=18080
kubectl -n agentic-ml port-forward svc/keycloak ${KC_LOCAL_PORT}:80 &
KC_PF_PID=$!
sleep 2

KC_URL="http://localhost:${KC_LOCAL_PORT}"

# Get admin token
ADMIN_TOKEN=$(curl -s -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" \
  -H "Content-Type: application/x-www-form-urlencoded" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

kc_api() {
  local method=$1
  local path=$2
  local body=${3:-}
  if [ -n "$body" ]; then
    curl -s -X "$method" "${KC_URL}/admin/realms/demo${path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -s -X "$method" "${KC_URL}/admin/realms/demo${path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

kc_api_status() {
  local method=$1
  local path=$2
  local body=${3:-}
  if [ -n "$body" ]; then
    curl -s -o /dev/null -w "%{http_code}" -X "$method" "${KC_URL}/admin/realms/demo${path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -s -o /dev/null -w "%{http_code}" -X "$method" "${KC_URL}/admin/realms/demo${path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

AGENTS=("orchestrator" "data-agent" "training-agent" "eval-agent" "deploy-agent" "model-registry")
ALL_CLIENTS=("${AGENTS[@]}" "demo-dashboard")

# 1. Set client attributes (jwt.credential.*, token exchange enabled)
echo "Setting client attributes..."
for agent in "${AGENTS[@]}"; do
  sa_sub="system:serviceaccount:agentic-ml:${agent}"
  CLIENT_JSON=$(kc_api GET "/clients?clientId=${agent}")
  CLIENT_UUID=$(echo "$CLIENT_JSON" | python3 -c "import sys,json; clients=json.load(sys.stdin); print(clients[0]['id'] if clients else '')" 2>/dev/null)
  if [ -z "$CLIENT_UUID" ]; then
    echo "  ${agent}: NOT FOUND (skipping)"
    continue
  fi

  # Get existing attributes and merge
  EXISTING_ATTRS=$(echo "$CLIENT_JSON" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)[0].get('attributes',{})))" 2>/dev/null)
  MERGED_ATTRS=$(python3 -c "
import json,sys
attrs = json.loads('${EXISTING_ATTRS}')
attrs['jwt.credential.issuer'] = 'kubernetes'
attrs['jwt.credential.sub'] = '${sa_sub}'
attrs['standard.token.exchange.enabled'] = 'true'
print(json.dumps(attrs))
")
  STATUS=$(kc_api_status PUT "/clients/${CLIENT_UUID}" "{\"id\":\"${CLIENT_UUID}\",\"clientId\":\"${agent}\",\"attributes\":${MERGED_ATTRS}}")
  echo "  ${agent}: ${STATUS}"
done

# 2. Add audience mapper directly on each client
echo "Adding client audience mappers..."
for agent in "${AGENTS[@]}"; do
  CLIENT_UUID=$(kc_api GET "/clients?clientId=${agent}" | python3 -c "import sys,json; clients=json.load(sys.stdin); print(clients[0]['id'] if clients else '')" 2>/dev/null)
  [ -z "$CLIENT_UUID" ] && continue

  EXISTING=$(kc_api GET "/clients/${CLIENT_UUID}/protocol-mappers/models" | python3 -c "import sys,json; print(','.join(m['name'] for m in json.load(sys.stdin)))" 2>/dev/null)
  if echo "$EXISTING" | grep -q "${agent}-audience-mapper"; then
    echo "  ${agent}: exists"
  else
    STATUS=$(kc_api_status POST "/clients/${CLIENT_UUID}/protocol-mappers/models" \
      "{\"name\":\"${agent}-audience-mapper\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",\"config\":{\"included.client.audience\":\"${agent}\",\"access.token.claim\":\"true\"}}")
    echo "  ${agent}: ${STATUS}"
  fi
done

# 3. Add orchestrator audience mapper to dashboard client
DASH_UUID=$(kc_api GET "/clients?clientId=demo-dashboard" | python3 -c "import sys,json; clients=json.load(sys.stdin); print(clients[0]['id'] if clients else '')" 2>/dev/null)
if [ -n "$DASH_UUID" ]; then
  EXISTING=$(kc_api GET "/clients/${DASH_UUID}/protocol-mappers/models" | python3 -c "import sys,json; print(','.join(m['name'] for m in json.load(sys.stdin)))" 2>/dev/null)
  if ! echo "$EXISTING" | grep -q "orchestrator-audience"; then
    STATUS=$(kc_api_status POST "/clients/${DASH_UUID}/protocol-mappers/models" \
      "{\"name\":\"orchestrator-audience\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",\"config\":{\"included.client.audience\":\"orchestrator\",\"access.token.claim\":\"true\"}}")
    echo "  demo-dashboard orchestrator audience: ${STATUS}"
  fi
fi

# 4. Assign all scopes (capability + audience) to all clients
echo "Assigning scopes to clients..."
ALL_SCOPE_JSON=$(kc_api GET "/client-scopes")

for client_name in "${ALL_CLIENTS[@]}"; do
  CLIENT_UUID=$(kc_api GET "/clients?clientId=${client_name}" | python3 -c "import sys,json; clients=json.load(sys.stdin); print(clients[0]['id'] if clients else '')" 2>/dev/null)
  [ -z "$CLIENT_UUID" ] && continue

  # Get scope IDs that we care about
  SCOPE_IDS=$(echo "$ALL_SCOPE_JSON" | python3 -c "
import sys,json
scopes = json.load(sys.stdin)
wanted = {'read:features','write:model-registry','provision:gpu','read:test-data','write:eval-reports','deploy:staging'}
for s in scopes:
    if s['name'].startswith('aud:') or s['name'] in wanted:
        print(s['id'])
")
  for scope_id in $SCOPE_IDS; do
    kc_api_status PUT "/clients/${CLIENT_UUID}/default-client-scopes/${scope_id}" > /dev/null
  done
  echo "  ${client_name}: scopes assigned"
done

# Clean up port-forward
kill $KC_PF_PID 2>/dev/null || true
wait $KC_PF_PID 2>/dev/null || true

echo "REST API configuration complete."

echo ""
echo "=== Keycloak configuration complete ==="
echo ""
echo "Demo user: alice / demo"
echo "Dashboard client: demo-dashboard (public)"
echo "Agent clients: federated-jwt with K8s SA tokens"
