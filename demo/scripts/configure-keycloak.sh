#!/bin/bash -e
# Configure Keycloak for the agentic IAM demo
# Based on the Klaviger oauth-token-exchange example

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
declare -A SCOPE_IDS

for scope in "${SCOPES[@]}"; do
  SCOPE_ID=$($KCADMIN create client-scopes -r demo -s "name=${scope}" -s protocol="openid-connect" -i 2>/dev/null || echo "")
  if [ -z "$SCOPE_ID" ]; then
    SCOPE_ID=$($KCADMIN get client-scopes -r demo -q "name=${scope}" --fields id --format csv --noquotes 2>/dev/null)
  fi
  SCOPE_IDS[$scope]=$SCOPE_ID
  echo "  ${scope} -> ${SCOPE_ID}"
done

# Create audience mappers for each agent client scope
# This ensures tokens include the correct audience claim
echo "Creating audience mappers..."
AGENTS=("orchestrator" "data-agent" "training-agent" "eval-agent" "deploy-agent" "model-registry")
for agent in "${AGENTS[@]}"; do
  # Create a scope for the agent audience
  AUD_SCOPE_ID=$($KCADMIN create client-scopes -r demo -s "name=aud:${agent}" -s protocol="openid-connect" -i 2>/dev/null || echo "")
  if [ -n "$AUD_SCOPE_ID" ]; then
    $KCADMIN create "client-scopes/${AUD_SCOPE_ID}/protocol-mappers/models" -r demo \
      -s "name=${agent}-audience-mapper" \
      -s protocol="openid-connect" \
      -s protocolMapper="oidc-audience-mapper" \
      -s "config={\"included.client.audience\":\"${agent}\", \"access.token.claim\":\"true\"}" 2>/dev/null || true
    echo "  aud:${agent} -> ${AUD_SCOPE_ID}"
  fi
done

# Create agent clients with federated JWT auth (K8s SA tokens)
echo "Creating agent clients..."

create_agent_client() {
  local name=$1
  local sa_sub="system:serviceaccount:agentic-ml:${name}"

  echo "  Creating client: ${name} (sub: ${sa_sub})"
  $KCADMIN create clients -r demo \
    -s "clientId=${name}" \
    -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=true \
    -s "clientAuthenticatorType=federated-jwt" \
    2>/dev/null || echo "    (client may already exist)"

  # Set attributes separately using JSON body (kcadm -s doesn't handle dotted keys)
  CLIENT_ID=$($KCADMIN get clients -r demo -q "clientId=${name}" --fields id --format csv --noquotes 2>/dev/null)
  if [ -n "$CLIENT_ID" ]; then
    $KCADMIN update "clients/${CLIENT_ID}" -r demo \
      -b "{\"attributes\":{\"jwt.credential.issuer\":\"kubernetes\",\"jwt.credential.sub\":\"${sa_sub}\",\"standard.token.exchange.enabled\":\"true\"}}" \
      2>/dev/null || echo "    (failed to set attributes for ${name})"
    echo "    attributes set: issuer=kubernetes, sub=${sa_sub}"
  fi
}

for agent in "${AGENTS[@]}"; do
  create_agent_client "$agent"
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

# Add orchestrator audience mapper to dashboard client so user tokens include orchestrator audience
echo "Adding orchestrator audience to dashboard client..."
DASH_CLIENT_ID=$($KCADMIN get clients -r demo -q clientId=demo-dashboard --fields id --format csv --noquotes 2>/dev/null)
if [ -n "$DASH_CLIENT_ID" ]; then
  $KCADMIN create "clients/${DASH_CLIENT_ID}/protocol-mappers/models" -r demo \
    -s name="orchestrator-audience" \
    -s protocol="openid-connect" \
    -s protocolMapper="oidc-audience-mapper" \
    -s 'config={"included.client.audience":"orchestrator", "access.token.claim":"true"}' 2>/dev/null || true
  echo "  orchestrator audience mapper added"
fi

# Assign all scopes to all agent clients (agents will request only what they need)
echo "Assigning scopes to clients..."
ALL_SCOPE_IDS=()
for scope in "${SCOPES[@]}"; do
  ALL_SCOPE_IDS+=("${SCOPE_IDS[$scope]}")
done

# Also get audience scope IDs
for agent in "${AGENTS[@]}"; do
  AUD_ID=$($KCADMIN get client-scopes -r demo -q "name=aud:${agent}" --fields id --format csv --noquotes 2>/dev/null || echo "")
  if [ -n "$AUD_ID" ]; then
    ALL_SCOPE_IDS+=("$AUD_ID")
  fi
done

for client in "${AGENTS[@]}" demo-dashboard; do
  CLIENT_ID=$($KCADMIN get clients -r demo -q "clientId=${client}" --fields id --format csv --noquotes 2>/dev/null)
  if [ -n "$CLIENT_ID" ]; then
    for scope_id in "${ALL_SCOPE_IDS[@]}"; do
      if [ -n "$scope_id" ]; then
        $KCADMIN update "clients/${CLIENT_ID}/default-client-scopes/${scope_id}" -r demo 2>/dev/null || true
      fi
    done
    echo "  ${client} -> scopes assigned"
  fi
done

echo ""
echo "=== Keycloak configuration complete ==="
echo ""
echo "Demo user: alice / demo"
echo "Dashboard client: demo-dashboard (public)"
echo "Agent clients: federated-jwt with K8s SA tokens"
