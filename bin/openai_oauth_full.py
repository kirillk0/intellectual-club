#!/usr/bin/env python3
"""
OpenAI OAuth Full Flow - Pure Standard Library
Generates URL, starts callback server, exchanges code for tokens
"""
import base64
import hashlib
import secrets
import json
import urllib.parse
import urllib.request
import webbrowser
import http.server
import socketserver
import threading
import sys
import time

# Configuration
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
TOKEN_URL = "https://auth.openai.com/oauth/token"
REDIRECT_URI = "http://localhost:1455/auth/callback"
SCOPE = "openid profile email offline_access"
PORT = 1455


class OAuthServer(http.server.HTTPServer):
    """Custom HTTP server to capture OAuth callback"""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.auth_code = None
        self.auth_state = None
        self.auth_error = None
        self._shutdown = False
    
    def serve_until_callback(self, timeout=300):
        """Serve until we get callback or timeout"""
        start_time = time.time()
        while not self._shutdown and (time.time() - start_time) < timeout:
            self.timeout = 1.0
            try:
                self.handle_request()
            except socketserver.socket.timeout:
                continue
            if self.auth_code or self.auth_error:
                break
    
    def shutdown_server(self):
        """Signal shutdown"""
        self._shutdown = True


class CallbackHandler(http.server.BaseHTTPRequestHandler):
    """Handle OAuth callback"""
    
    def log_message(self, format, *args):
        pass  # Suppress logs
    
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        
        code = params.get('code', [None])[0]
        state = params.get('state', [None])[0]
        error = params.get('error', [None])[0]
        error_desc = params.get('error_description', [''])[0]
        
        server = self.server
        
        # Ignore subsequent requests after we have code
        if server.auth_code or server.auth_error:
            self._send_response(200, b"Already processed", "text/plain")
            return
        
        if error:
            server.auth_error = f"{error}: {error_desc}"
            self._send_error_page(error, error_desc)
            threading.Thread(target=server.shutdown_server, daemon=True).start()
        elif code:
            server.auth_code = code
            server.auth_state = state
            self._send_success_page()
            threading.Thread(target=server.shutdown_server, daemon=True).start()
        else:
            # Ignore requests without code (favicon.ico, etc.)
            self._send_response(404, b"Not found", "text/plain")
    
    def _send_success_page(self):
        html = """<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Authentication Successful</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
               display: flex; justify-content: center; align-items: center; height: 100vh; 
               margin: 0; background: #f5f5f5; }
        .box { background: white; padding: 40px; border-radius: 12px; 
               box-shadow: 0 4px 12px rgba(0,0,0,0.15); text-align: center; max-width: 400px; }
        h1 { color: #10a37f; margin-bottom: 16px; }
        p { color: #666; line-height: 1.5; }
        .icon { font-size: 48px; margin-bottom: 16px; }
    </style>
</head>
<body>
    <div class="box">
        <div class="icon">OK</div>
        <h1>Authentication Successful!</h1>
        <p>You can close this window and return to the terminal.<br>
        The authorization code has been captured.</p>
    </div>
</body>
</html>""".encode('utf-8')
        self._send_response(200, html, "text/html; charset=utf-8")
    
    def _send_error_page(self, error, description):
        html = f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Authentication Error</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
               display: flex; justify-content: center; align-items: center; height: 100vh; 
               margin: 0; background: #f5f5f5; }}
        .box {{ background: white; padding: 40px; border-radius: 12px; 
                box-shadow: 0 4px 12px rgba(0,0,0,0.15); text-align: center; max-width: 400px; }}
        h1 {{ color: #dc3545; margin-bottom: 16px; }}
        p {{ color: #666; line-height: 1.5; }}
        .error {{ background: #f8f9fa; padding: 12px; border-radius: 6px; 
                  font-family: monospace; font-size: 12px; color: #dc3545; margin-top: 16px; }}
    </style>
</head>
<body>
    <div class="box">
        <h1>Authentication Failed</h1>
        <p><strong>{error}</strong></p>
        <div class="error">{description}</div>
    </div>
</body>
</html>""".encode('utf-8')
        self._send_response(400, html, "text/html; charset=utf-8")
    
    def _send_response(self, code, body, content_type="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)


def generate_pkce():
    """Generate PKCE verifier and challenge"""
    verifier_bytes = secrets.token_bytes(32)
    code_verifier = base64.urlsafe_b64encode(verifier_bytes).rstrip(b'=').decode('ascii')
    challenge_hash = hashlib.sha256(code_verifier.encode('ascii')).digest()
    code_challenge = base64.urlsafe_b64encode(challenge_hash).rstrip(b'=').decode('ascii')
    return code_verifier, code_challenge


def build_auth_url(code_challenge, state):
    """Build authorization URL"""
    params = {
        "response_type": "code",
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "scope": SCOPE,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
        "state": state,
        "id_token_add_organizations": "true",
        "codex_cli_simplified_flow": "true",
        "originator": "codex_cli_rs"
    }
    return f"{AUTHORIZE_URL}?{urllib.parse.urlencode(params)}"


def exchange_code_for_tokens(code, code_verifier):
    """Exchange authorization code for tokens"""
    data = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "client_id": CLIENT_ID,
        "code": code,
        "code_verifier": code_verifier,
        "redirect_uri": REDIRECT_URI
    }).encode('utf-8')
    
    req = urllib.request.Request(
        TOKEN_URL,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST"
    )
    
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode('utf-8')
        try:
            error_json = json.loads(error_body)
            raise Exception(f"Token exchange failed: {error_json.get('error_description', error_body)}")
        except json.JSONDecodeError:
            raise Exception(f"Token exchange failed: {error_body}")


def print_token_info(tokens):
    """Pretty print token information"""
    print("\n" + "="*70)
    print("SUCCESS! Tokens received:")
    print("="*70)
    
    # Decode JWT to show claims
    if 'id_token' in tokens:
        try:
            parts = tokens['id_token'].split('.')
            if len(parts) == 3:
                # Add padding if needed
                payload_b64 = parts[1]
                padding_needed = 4 - len(payload_b64) % 4
                if padding_needed != 4:
                    payload_b64 += '=' * padding_needed
                payload = base64.urlsafe_b64decode(payload_b64)
                claims = json.loads(payload)
                print("\nUser Info from ID Token:")
                if 'email' in claims:
                    print(f"   Email: {claims['email']}")
                if 'https://api.openai.com/auth' in claims:
                    auth_data = claims['https://api.openai.com/auth']
                    if 'chatgpt_account_id' in auth_data:
                        print(f"   Account ID: {auth_data['chatgpt_account_id']}")
        except Exception as e:
            pass
    
    print("\nREFRESH TOKEN (save this!):")
    print(f"   {tokens.get('refresh_token', 'N/A')}")
    
    print("\nACCESS TOKEN:")
    print(f"   {tokens.get('access_token', 'N/A')}")
    
    print(f"\nExpires in: {tokens.get('expires_in', 'N/A')} seconds")
    print(f"Token type: {tokens.get('token_type', 'N/A')}")
    
    print("\n" + "="*70)
    print("Save the refresh token securely!")
    print("   It can be used to get new access tokens without re-authenticating.")
    print("="*70)


def refresh_access_token(refresh_token):
    """Refresh access token using refresh token"""
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": CLIENT_ID
    }).encode('utf-8')
    
    req = urllib.request.Request(
        TOKEN_URL,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST"
    )
    
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode('utf-8')
        try:
            error_json = json.loads(error_body)
            raise Exception(f"Token refresh failed: {error_json.get('error_description', error_body)}")
        except json.JSONDecodeError:
            raise Exception(f"Token refresh failed: {error_body}")


def do_oauth_flow():
    """Run full OAuth flow"""
    print("="*70)
    print("OpenAI OAuth - Full Authorization Flow")
    print("="*70)
    
    # Generate PKCE
    print("\nGenerating PKCE codes...")
    code_verifier, code_challenge = generate_pkce()
    state = secrets.token_hex(16)
    print(f"   code_verifier: {code_verifier[:20]}...")
    print(f"   state:         {state}")
    
    # Build auth URL
    auth_url = build_auth_url(code_challenge, state)
    
    # Start callback server
    print(f"\nStarting callback server on port {PORT}...")
    try:
        server = OAuthServer(("127.0.0.1", PORT), CallbackHandler)
    except OSError as e:
        if e.errno == 98:  # Address already in use
            print(f"\nError: Port {PORT} is already in use!")
            print("   Another OAuth flow might be running, or a previous process didn't exit cleanly.")
            print(f"   Try: lsof -ti:{PORT} | xargs kill -9")
            sys.exit(1)
        raise
    
    server_thread = threading.Thread(target=server.serve_until_callback)
    server_thread.daemon = True
    server_thread.start()
    print("   Server started!")
    
    # Open browser
    print("\nOpening browser for authentication...")
    print(f"   URL: {auth_url[:80]}...")
    webbrowser.open(auth_url)
    
    # Wait for callback
    print("\nWaiting for callback from OpenAI (timeout: 5 minutes)...")
    print("   (Press Ctrl+C to cancel)")
    
    try:
        server_thread.join(timeout=300)
    except KeyboardInterrupt:
        print("\n\nCancelled by user")
        server.shutdown_server()
        sys.exit(1)
    
    if server.auth_error:
        print(f"\nOAuth Error: {server.auth_error}")
        sys.exit(1)
    
    if not server.auth_code:
        print("\nTimeout: No callback received within 5 minutes")
        sys.exit(1)
    
    print(f"\nAuthorization code received!")
    print(f"   Code: {server.auth_code[:20]}...")
    
    # Exchange for tokens
    print("\nExchanging code for tokens...")
    try:
        tokens = exchange_code_for_tokens(server.auth_code, code_verifier)
        print_token_info(tokens)
    except Exception as e:
        print(f"\nToken exchange failed: {e}")
        sys.exit(1)


def do_refresh_token(refresh_token):
    """Refresh token without user interaction"""
    print("="*70)
    print("OpenAI OAuth - Token Refresh")
    print("="*70)
    print("\nRefreshing access token...")
    
    try:
        tokens = refresh_access_token(refresh_token)
        print_token_info(tokens)
    except Exception as e:
        print(f"\nToken refresh failed: {e}")
        sys.exit(1)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--refresh":
        if len(sys.argv) < 3:
            print("Usage: python3 openai_oauth_full.py --refresh <refresh_token>")
            sys.exit(1)
        do_refresh_token(sys.argv[2])
    else:
        do_oauth_flow()


if __name__ == "__main__":
    main()
