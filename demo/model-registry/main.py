"""
Model Registry Mock Service

Simulates a model registry for the IAM demo.
- In classic mode: accepts writes from any caller (no auth check)
- In agentic mode: checks authorization via Klaviger sidecar (only training-agent can write)
"""

import http.server
import json
import os
import time
import base64

PORT = int(os.environ.get("PORT", "8080"))
BIND = os.environ.get("BIND_ADDRESS", "0.0.0.0")
AUTH_MODE = os.environ.get("AUTH_MODE", "none")  # none | check-scope
REQUIRED_SCOPE = os.environ.get("REQUIRED_SCOPE", "write:model-registry")

models = []


def decode_jwt_claims(token):
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return None
        payload = parts[1]
        padding = 4 - len(payload) % 4
        if padding != 4:
            payload += "=" * padding
        decoded = base64.urlsafe_b64decode(payload)
        return json.loads(decoded)
    except Exception:
        return None


class RegistryHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_json(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode("utf-8"))

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"status": "ok", "service": "model-registry"})
            return

        if self.path == "/models":
            self.send_json(200, {"models": models})
            return

        self.send_json(200, {"service": "model-registry", "models_count": len(models)})

    def do_POST(self):
        if self.path == "/write":
            # Read request body
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"

            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                data = {}

            # Check authorization if enabled
            if AUTH_MODE == "check-scope":
                auth_header = self.headers.get("Authorization", "")
                if not auth_header.startswith("Bearer "):
                    self.send_json(401, {
                        "error": "unauthorized",
                        "message": "No bearer token provided",
                    })
                    return

                claims = decode_jwt_claims(auth_header[7:])
                if claims:
                    scopes = claims.get("scope", "")
                    # Check the X-Caller-Identity header set by Klaviger
                    # to verify the actual calling agent identity
                    caller_identity = self.headers.get("X-Forwarded-Client-Cert", "")

                    if REQUIRED_SCOPE not in scopes:
                        self.send_json(403, {
                            "error": "forbidden",
                            "message": f"Missing required scope: {REQUIRED_SCOPE}",
                            "caller_scopes": scopes,
                            "caller_subject": claims.get("sub", "unknown"),
                            "caller_actor": claims.get("act", {}).get("sub", "none"),
                        })
                        return

                    # Also check REQUIRED_CALLER if set (defense in depth)
                    required_caller = os.environ.get("REQUIRED_CALLER", "")
                    if required_caller:
                        # Check X-Request-Source header injected by calling agent
                        request_source = self.headers.get("X-Request-Source", "")
                        if required_caller not in request_source:
                            self.send_json(403, {
                                "error": "forbidden",
                                "message": f"Caller not authorized for writes",
                                "required_caller": required_caller,
                                "actual_caller": request_source or "unknown",
                            })
                            return

            # Accept the write
            entry = {
                "model_name": data.get("model_name", "unnamed"),
                "version": data.get("version", "0.0"),
                "written_by": data.get("written_by", "unknown"),
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            models.append(entry)

            caller_info = "unknown"
            auth_header = self.headers.get("Authorization", "")
            if auth_header.startswith("Bearer "):
                claims = decode_jwt_claims(auth_header[7:])
                if claims:
                    caller_info = claims.get("sub", "unknown")

            print(f"[model-registry] WRITE accepted from {caller_info}: {entry['model_name']} v{entry['version']}", flush=True)

            self.send_json(200, {
                "status": "written",
                "entry": entry,
                "total_models": len(models),
            })
            return

        self.send_json(404, {"error": "not found"})


def main():
    server = http.server.HTTPServer((BIND, PORT), RegistryHandler)
    print(f"[model-registry] listening on {BIND}:{PORT}", flush=True)
    print(f"[model-registry] auth_mode: {AUTH_MODE}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
