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
# Use REST API via python for: client attributes, audience mappers, scope assignments.
echo ""
echo "Configuring client attributes and scope assignments via REST API..."

# Find an agent pod with python to run REST API calls
AGENT_POD=$(kubectl -n agentic-ml get pod -l app=ml-agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$AGENT_POD" ]; then
  # Fall back to any pod with python
  AGENT_POD=$(kubectl -n agentic-ml get pod -l agent=orchestrator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

if [ -z "$AGENT_POD" ]; then
  echo "WARNING: No agent pod available for REST API calls."
  echo "Client attributes and scope assignments must be configured manually."
  echo "Run this script again after agent pods are deployed."
else
  kubectl -n agentic-ml exec "$AGENT_POD" -c agent -- python3 -c "
import urllib.request, urllib.parse, json, sys

KC = 'http://keycloak.agentic-ml.svc'
AGENTS = ['orchestrator', 'data-agent', 'training-agent', 'eval-agent', 'deploy-agent', 'model-registry']
ALL_CLIENTS = AGENTS + ['demo-dashboard']

# Get admin token
data = urllib.parse.urlencode({
    'grant_type': 'password', 'client_id': 'admin-cli',
    'username': 'admin', 'password': 'admin',
}).encode()
req = urllib.request.Request(f'{KC}/realms/master/protocol/openid-connect/token', data=data)
req.add_header('Content-Type', 'application/x-www-form-urlencoded')
resp = urllib.request.urlopen(req, timeout=10)
admin_token = json.loads(resp.read())['access_token']

def api(method, path, body=None):
    url = f'{KC}/admin/realms/demo{path}'
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Authorization', f'Bearer {admin_token}')
    req.add_header('Content-Type', 'application/json')
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        content = resp.read().decode()
        return resp.status, json.loads(content) if content else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def api_get(path):
    s, r = api('GET', path)
    return r

# 1. Set client attributes (jwt.credential.*, token exchange enabled)
print('Setting client attributes...')
clients_resp = api_get('/clients?max=100')
client_map = {c['clientId']: c for c in clients_resp}

for agent in AGENTS:
    if agent not in client_map:
        print(f'  {agent}: NOT FOUND (skipping)')
        continue
    c = client_map[agent]
    cid = c['id']
    sa_sub = f'system:serviceaccount:agentic-ml:{agent}'
    attrs = c.get('attributes', {})
    attrs['jwt.credential.issuer'] = 'kubernetes'
    attrs['jwt.credential.sub'] = sa_sub
    attrs['standard.token.exchange.enabled'] = 'true'
    status, _ = api('PUT', f'/clients/{cid}', {
        'id': cid, 'clientId': agent, 'attributes': attrs,
    })
    print(f'  {agent}: {\"ok\" if status == 204 else f\"status {status}\"}')

# 2. Add audience mapper directly on each client (belt and suspenders)
print('Adding client audience mappers...')
for agent in AGENTS:
    if agent not in client_map:
        continue
    cid = client_map[agent]['id']
    _, mappers = api('GET', f'/clients/{cid}/protocol-mappers/models')
    existing = [m['name'] for m in (mappers or [])] if isinstance(mappers, list) else []
    mapper_name = f'{agent}-audience-mapper'
    if mapper_name not in existing:
        status, _ = api('POST', f'/clients/{cid}/protocol-mappers/models', {
            'name': mapper_name, 'protocol': 'openid-connect',
            'protocolMapper': 'oidc-audience-mapper',
            'config': {'included.client.audience': agent, 'access.token.claim': 'true'},
        })
        print(f'  {agent}: {\"ok\" if status == 201 else f\"status {status}\"}')
    else:
        print(f'  {agent}: exists')

# 3. Add orchestrator audience mapper to dashboard client
if 'demo-dashboard' in client_map:
    cid = client_map['demo-dashboard']['id']
    _, mappers = api('GET', f'/clients/{cid}/protocol-mappers/models')
    existing = [m['name'] for m in (mappers or [])] if isinstance(mappers, list) else []
    if 'orchestrator-audience' not in existing:
        status, _ = api('POST', f'/clients/{cid}/protocol-mappers/models', {
            'name': 'orchestrator-audience', 'protocol': 'openid-connect',
            'protocolMapper': 'oidc-audience-mapper',
            'config': {'included.client.audience': 'orchestrator', 'access.token.claim': 'true'},
        })
        print(f'  demo-dashboard orchestrator audience: {\"ok\" if status == 201 else f\"status {status}\"}')

# 4. Assign all scopes (capability + audience) to all clients
print('Assigning scopes to clients...')
scopes = api_get('/client-scopes')
scope_ids = {s['name']: s['id'] for s in scopes}

for client_name in ALL_CLIENTS:
    if client_name not in client_map:
        continue
    cid = client_map[client_name]['id']
    for scope_name, scope_id in scope_ids.items():
        if scope_name.startswith('aud:') or scope_name in [
            'read:features', 'write:model-registry', 'provision:gpu',
            'read:test-data', 'write:eval-reports', 'deploy:staging',
        ]:
            api('PUT', f'/clients/{cid}/default-client-scopes/{scope_id}')
    print(f'  {client_name}: scopes assigned')

print('REST API configuration complete.')
" 2>&1
fi

echo ""
echo "=== Keycloak configuration complete ==="
echo ""
echo "Demo user: alice / demo"
echo "Dashboard client: demo-dashboard (public)"
echo "Agent clients: federated-jwt with K8s SA tokens"
