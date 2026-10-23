#!/usr/bin/env python3
"""One-time Spotify login for KoPlay (KOReader plugin).

Runs the Authorization Code + PKCE flow in your browser and writes koplay.json
(client_id + refresh_token). If a Kindle is mounted over USB on macOS, it offers
to copy the file to koreader/settings/ directly.

Usage: python3 koplay_auth.py [CLIENT_ID]
"""

import base64
import hashlib
import http.server
import json
import secrets
import shutil
import sys
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

REDIRECT_URI = "http://127.0.0.1:8888/callback"
SCOPES = " ".join([
    "user-read-playback-state",
    "user-read-currently-playing",
    "user-modify-playback-state",
    "user-read-recently-played",
    "user-library-read",
    "playlist-read-private",
    "playlist-read-collaborative",
])
KINDLE_SETTINGS = Path("/Volumes/Kindle/koreader/settings")
OUT_FILE = Path(__file__).resolve().parent / "koplay.json"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def wait_for_code(expected_state: str) -> str:
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if not self.path.startswith("/callback"):
                self.send_response(404)
                self.end_headers()
                return
            if query.get("state", [None])[0] != expected_state:
                result["error"] = "state mismatch"
            elif "error" in query:
                result["error"] = query["error"][0]
            else:
                result["code"] = query.get("code", [None])[0]
            ok = "code" in result
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            msg = "Done! You can close this tab and go back to the terminal." if ok else f"Error: {result.get('error')}"
            self.wfile.write(f"<h2 style='font-family:sans-serif'>{msg}</h2>".encode())

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 8888), Handler)
    while not result:
        server.handle_request()
    server.server_close()
    if "error" in result:
        sys.exit(f"Login failed: {result['error']}")
    return result["code"]


def exchange_code(client_id: str, code: str, verifier: str) -> dict:
    body = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": REDIRECT_URI,
        "client_id": client_id,
        "code_verifier": verifier,
    }).encode()
    req = urllib.request.Request(
        "https://accounts.spotify.com/api/token",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def main():
    client_id = sys.argv[1] if len(sys.argv) > 1 else input("Spotify Client ID: ").strip()
    if not client_id:
        sys.exit("A Client ID is required.")

    verifier = b64url(secrets.token_bytes(64))
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    state = secrets.token_urlsafe(16)
    url = "https://accounts.spotify.com/authorize?" + urllib.parse.urlencode({
        "response_type": "code",
        "client_id": client_id,
        "scope": SCOPES,
        "redirect_uri": REDIRECT_URI,
        "code_challenge_method": "S256",
        "code_challenge": challenge,
        "state": state,
    })

    print("Opening the Spotify login page in your browser…")
    print(f"If it doesn't open, visit this address:\n{url}\n")
    webbrowser.open(url)
    code = wait_for_code(state)

    tokens = exchange_code(client_id, code, verifier)
    if "refresh_token" not in tokens:
        sys.exit(f"Unexpected response: {tokens}")

    OUT_FILE.write_text(json.dumps({"client_id": client_id, "refresh_token": tokens["refresh_token"]}))
    print(f"Saved: {OUT_FILE}")

    if KINDLE_SETTINGS.is_dir():
        if input("A Kindle seems to be connected. Copy the file there? [Y/n] ").strip().lower() in ("", "y", "yes"):
            shutil.copy(OUT_FILE, KINDLE_SETTINGS / "koplay.json")
            print(f"Copied: {KINDLE_SETTINGS / 'koplay.json'}")
    else:
        print("Copy this file into koreader/settings/ on your e-reader.")


if __name__ == "__main__":
    main()
