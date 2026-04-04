"""
ML Pipeline Demo Agent

A simple HTTP agent for demonstrating classic vs agentic IAM.
Each agent:
- Shows its identity info (name, service account, token claims)
- Can call downstream agents in the pipeline chain
- Serves an Agent Card at /.well-known/agent.json (if configured)
- Exposes /api/info for the dashboard to query
"""

import http.server
import json
import os
import sys
import urllib.request
import urllib.error
import urllib.parse
import base64
import time

NAME = os.environ.get("AGENT_NAME", "unknown")
PORT = int(os.environ.get("PORT", "8080"))
BIND = os.environ.get("BIND_ADDRESS", "0.0.0.0")
DOWNSTREAM = os.environ.get("DOWNSTREAM", "")  # comma-separated list of downstream service URLs
AGENT_SKILLS = os.environ.get("AGENT_SKILLS", "")
AGENT_CAPABILITIES = os.environ.get("AGENT_CAPABILITIES", "")
AGENT_IDENTITY = os.environ.get("AGENT_IDENTITY", "")
ENABLE_AGENT_CARD = os.environ.get("ENABLE_AGENT_CARD", "false").lower() == "true"
MODEL_REGISTRY_URL = os.environ.get("MODEL_REGISTRY_URL", "")
KEYCLOAK_TOKEN_URL = os.environ.get("KEYCLOAK_TOKEN_URL", "")
SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_NAMESPACE_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"

HTTP_PROXY = os.environ.get("HTTP_PROXY", os.environ.get("http_proxy", ""))


def read_file_safe(path):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except Exception:
        return ""


def decode_jwt_claims(token):
    """Decode JWT payload without verification (for display only)."""
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return None
        payload = parts[1]
        # Add padding
        padding = 4 - len(payload) % 4
        if padding != 4:
            payload += "=" * padding
        decoded = base64.urlsafe_b64decode(payload)
        return json.loads(decoded)
    except Exception:
        return None


def get_identity_info(headers):
    """Gather identity information from the environment and request."""
    sa_token = read_file_safe(SA_TOKEN_PATH)
    namespace = read_file_safe(SA_NAMESPACE_PATH)

    # Decode token claims if present
    token_claims = None
    if sa_token:
        token_claims = decode_jwt_claims(sa_token)

    # Check for Authorization header (incoming token)
    auth_header = headers.get("Authorization", "")
    incoming_claims = None
    if auth_header.startswith("Bearer "):
        incoming_claims = decode_jwt_claims(auth_header[7:])

    # Extract trust headers
    trust_headers = {
        "x-principal-id": headers.get("X-Principal-Id", headers.get("x-principal-id", "")),
        "x-caller-id": headers.get("X-Caller-Id", headers.get("x-caller-id", "")),
        "x-caller-type": headers.get("X-Caller-Type", headers.get("x-caller-type", "")),
        "x-request-id": headers.get("X-Request-Id", headers.get("x-request-id", "")),
        "x-trust-hop-kind": headers.get("X-Trust-Hop-Kind", headers.get("x-trust-hop-kind", "")),
    }

    # Determine identity display
    sa_name = ""
    if token_claims and "sub" in token_claims:
        sa_name = token_claims["sub"]
    elif token_claims and "kubernetes.io" in token_claims:
        k8s = token_claims["kubernetes.io"]
        sa_name = f"system:serviceaccount:{k8s.get('namespace', '?')}:{k8s.get('serviceaccount', {}).get('name', '?')}"

    # Extract subject and actor from incoming token (OBO)
    subject = ""
    actor = ""
    scopes = ""
    audience = ""
    if incoming_claims:
        subject = incoming_claims.get("sub", "")
        if "act" in incoming_claims:
            actor = incoming_claims["act"].get("sub", "")
        scopes = incoming_claims.get("scope", "")
        aud = incoming_claims.get("aud", "")
        if isinstance(aud, list):
            audience = ", ".join(aud)
        else:
            audience = str(aud)

    return {
        "agent_name": NAME,
        "namespace": namespace,
        "service_account": sa_name,
        "subject": subject,
        "actor": actor,
        "scopes": scopes,
        "audience": audience,
        "trust_headers": trust_headers,
        "incoming_token_claims": incoming_claims,
        "sa_token_claims": token_claims,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def call_downstream(url, headers):
    """Call a downstream agent and return its response."""
    try:
        req = urllib.request.Request(url, data=b'{}', method="POST")

        # Forward Authorization header; if none, use own SA token as subject token
        auth = headers.get("Authorization", "")
        if not auth:
            sa_token = read_file_safe(SA_TOKEN_PATH)
            if sa_token:
                auth = f"Bearer {sa_token}"
        if auth:
            req.add_header("Authorization", auth)

        # Forward trust headers
        for h in ["X-Principal-Id", "X-Caller-Id", "X-Caller-Type", "X-Request-Id", "X-Trust-Hop-Kind"]:
            val = headers.get(h, headers.get(h.lower(), ""))
            if val:
                req.add_header(h, val)

        # Use proxy if configured
        if HTTP_PROXY:
            proxy_handler = urllib.request.ProxyHandler({"http": HTTP_PROXY, "https": HTTP_PROXY})
            opener = urllib.request.build_opener(proxy_handler)
        else:
            opener = urllib.request.build_opener()

        resp = opener.open(req, timeout=10)
        body = resp.read().decode("utf-8")
        return {"url": url, "status": resp.status, "response": json.loads(body)}
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8")
        except Exception:
            pass
        return {"url": url, "status": e.code, "error": body}
    except Exception as e:
        return {"url": url, "status": 0, "error": str(e)}


def try_model_registry_write(headers):
    """Attempt to write to model-registry (Break 2 demonstration)."""
    if not MODEL_REGISTRY_URL:
        return None
    try:
        data = json.dumps({
            "model_name": "test-model",
            "version": "1.0",
            "written_by": NAME,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }).encode("utf-8")

        req = urllib.request.Request(
            MODEL_REGISTRY_URL + "/write",
            data=data,
            method="POST",
        )
        req.add_header("Content-Type", "application/json")

        # Forward auth
        auth = headers.get("Authorization", "")
        if auth:
            req.add_header("Authorization", auth)

        # Forward SA token if no auth header
        if not auth:
            sa_token = read_file_safe(SA_TOKEN_PATH)
            if sa_token:
                req.add_header("Authorization", f"Bearer {sa_token}")

        if HTTP_PROXY:
            proxy_handler = urllib.request.ProxyHandler({"http": HTTP_PROXY, "https": HTTP_PROXY})
            opener = urllib.request.build_opener(proxy_handler)
        else:
            opener = urllib.request.build_opener()

        resp = opener.open(req, timeout=10)
        body = resp.read().decode("utf-8")
        return {"status": resp.status, "response": json.loads(body), "allowed": True}
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8")
        except Exception:
            pass
        return {"status": e.code, "error": body, "allowed": False}
    except Exception as e:
        return {"status": 0, "error": str(e), "allowed": False}


def build_agent_card():
    """Build A2A Agent Card."""
    skills = [s.strip() for s in AGENT_SKILLS.split(",") if s.strip()]
    capabilities = [c.strip() for c in AGENT_CAPABILITIES.split(",") if c.strip()]
    return {
        "name": NAME,
        "description": f"ML Pipeline {NAME} agent",
        "skills": skills,
        "capabilities": capabilities,
        "identity": AGENT_IDENTITY,
        "endpoint": f"http://{NAME}",
        "version": "1.0.0",
    }


class DemoHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Quiet logging
        pass

    def send_json(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Principal-Id, X-Caller-Id, X-Caller-Type, X-Request-Id, X-Trust-Hop-Kind")
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode("utf-8"))

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Principal-Id, X-Caller-Id, X-Caller-Type, X-Request-Id, X-Trust-Hop-Kind")
        self.end_headers()

    def do_GET(self):
        if self.path == "/.well-known/agent.json":
            if ENABLE_AGENT_CARD:
                self.send_json(200, build_agent_card())
            else:
                self.send_json(404, {"error": "Agent Card not enabled"})
            return

        if self.path == "/health":
            self.send_json(200, {"status": "ok", "agent": NAME})
            return

        if self.path == "/api/info":
            info = get_identity_info(dict(self.headers))
            self.send_json(200, info)
            return

        # Default: show identity info as text
        info = get_identity_info(dict(self.headers))
        self.send_json(200, info)

    def do_POST(self):
        if self.path == "/api/login":
            # Get a Keycloak token for the demo user (from inside the cluster, correct issuer)
            if not KEYCLOAK_TOKEN_URL:
                self.send_json(500, {"error": "KEYCLOAK_TOKEN_URL not configured"})
                return
            content_length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(content_length)) if content_length else {}
            username = body.get("username", "alice")
            password = body.get("password", "demo")
            try:
                data = urllib.parse.urlencode({
                    "grant_type": "password",
                    "client_id": "demo-dashboard",
                    "username": username,
                    "password": password,
                    "scope": "openid",
                }).encode("utf-8")
                req = urllib.request.Request(KEYCLOAK_TOKEN_URL, data=data, method="POST")
                req.add_header("Content-Type", "application/x-www-form-urlencoded")
                resp = urllib.request.urlopen(req, timeout=10)
                token_data = json.loads(resp.read().decode("utf-8"))
                self.send_json(200, token_data)
            except urllib.error.HTTPError as e:
                err = e.read().decode("utf-8") if e.fp else ""
                self.send_json(e.code, {"error": err})
            except Exception as e:
                self.send_json(500, {"error": str(e)})
            return

        if self.path == "/api/run-pipeline":
            # Run the full pipeline: get own info, call downstream, optionally test model-registry
            info = get_identity_info(dict(self.headers))

            result = {
                "agent": info,
                "downstream_results": [],
                "model_registry_test": None,
            }

            # Call downstream agents
            if DOWNSTREAM:
                for url in DOWNSTREAM.split(","):
                    url = url.strip()
                    if url:
                        downstream_result = call_downstream(url + "/api/run-pipeline", dict(self.headers))
                        result["downstream_results"].append(downstream_result)

            # If this is the data-agent, try to write to model-registry (Break 2)
            if NAME == "data-agent" and MODEL_REGISTRY_URL:
                result["model_registry_test"] = try_model_registry_write(dict(self.headers))

            self.send_json(200, result)
            return

        # Generic POST handler
        info = get_identity_info(dict(self.headers))
        self.send_json(200, info)


def main():
    server = http.server.HTTPServer((BIND, PORT), DemoHandler)
    print(f"[{NAME}] listening on {BIND}:{PORT}", flush=True)
    print(f"[{NAME}] downstream: {DOWNSTREAM or 'none'}", flush=True)
    print(f"[{NAME}] model-registry: {MODEL_REGISTRY_URL or 'none'}", flush=True)
    print(f"[{NAME}] agent-card: {ENABLE_AGENT_CARD}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
