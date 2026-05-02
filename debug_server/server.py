#!/usr/bin/env python3
"""
WatchLogger Debug Server
========================
Minimal REST endpoint that accepts POST requests from the WatchLogger app
and prints the received payload to the console. Useful for development and
testing without a full PEF backend.

Usage:
    python3 server.py [--host 0.0.0.0] [--port 8888] [--token mytoken]

Then configure the Watch app with:
    endpoint_url: http://<your-mac-ip>:8888/api/logs
    auth_header:  Authorization
    auth_token:   Bearer mytoken

Requirements:
    pip install flask

The server also simulates the PEF pairing endpoints so the Watch app can
complete the full pairing flow against this server.
"""

import argparse
import json
import logging
import secrets
import time
from datetime import datetime, timezone
from typing import Any

from flask import Flask, jsonify, request

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

app = Flask(__name__)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("watchlogger-debug")

# In-memory storage for received events and active nonces
received_events: list[dict[str, Any]] = []
active_nonces: dict[str, dict[str, Any]] = {}  # nonce → {expires_at, token}

TOKEN: str = "debug-token"  # overridden by --token flag


# ---------------------------------------------------------------------------
# Auth helper
# ---------------------------------------------------------------------------

def check_auth() -> bool:
    """Returns True if the request carries the correct auth token."""
    auth = request.headers.get("Authorization", "")
    return auth == f"Bearer {TOKEN}"


# ---------------------------------------------------------------------------
# Pairing endpoints (mirrors PEF backend)
# ---------------------------------------------------------------------------

@app.route("/api/auth/pairing/request-nonce", methods=["GET"])
def request_nonce():
    """
    Returns a 6-digit pairing nonce valid for 5 minutes.
    The Watch app displays this code; the user enters it in the PEF web UI
    (or in this server's /pair endpoint for testing).
    """
    nonce = str(secrets.randbelow(900000) + 100000)
    expires_at = time.time() + 300
    pair_token = secrets.token_hex(24)
    active_nonces[nonce] = {"expires_at": expires_at, "token": pair_token, "paired": False}

    log.info(f"🔑 Nonce issued: {nonce}  (expires in 5 min)")
    log.info(f"   To pair: curl http://localhost:{app.config['PORT']}/pair/{nonce}")

    return jsonify({"nonce": nonce, "expires_in": 300})


@app.route("/api/auth/pairing/status", methods=["GET"])
def pairing_status():
    """
    Polled by the Watch app every 3 seconds.
    Returns 'waiting', 'paired' (with token), or 'expired'.
    """
    nonce = request.args.get("nonce", "")
    entry = active_nonces.get(nonce)

    if not entry:
        return jsonify({"status": "expired"})
    if time.time() > entry["expires_at"]:
        del active_nonces[nonce]
        return jsonify({"status": "expired"})
    if entry["paired"]:
        return jsonify({"status": "paired", "token": entry["token"]})

    return jsonify({"status": "waiting"})


@app.route("/pair/<nonce>", methods=["GET"])
def manual_pair(nonce: str):
    """
    Debug shortcut: call this URL in a browser or with curl to simulate
    the user entering the nonce in the PEF web UI.

    Example:
        curl http://localhost:8888/pair/123456
    """
    entry = active_nonces.get(nonce)
    if not entry:
        return jsonify({"error": "Nonce not found"}), 404
    if time.time() > entry["expires_at"]:
        return jsonify({"error": "Nonce expired"}), 410

    entry["paired"] = True
    log.info(f"✅ Nonce {nonce} paired  →  token: {entry['token']}")
    return jsonify({"status": "ok", "token": entry["token"]})


# ---------------------------------------------------------------------------
# Session status endpoint
# ---------------------------------------------------------------------------

@app.route("/api/status", methods=["GET"])
def session_status():
    """Health/session check. Returns 200 if token is valid."""
    if not check_auth():
        return jsonify({"error": "Unauthorized"}), 401
    return jsonify({"valid": True, "message": None})


# ---------------------------------------------------------------------------
# Main log receiver
# ---------------------------------------------------------------------------

@app.route("/api/logs", methods=["POST"])
def receive_log():
    """
    Accepts a single log event from the Watch app.

    Expected body shape:
    {
        "id":        "uuid",
        "type":      "off_phase" | "tremor_detected" | ...,
        "timestamp": "2026-05-02T08:00:00Z",
        // + arbitrary payload fields merged into top level
    }

    Returns 201 on success. Returns 409 if event ID was already received
    (idempotency — safe for Watch app to retry).
    """
    if not check_auth():
        log.warning(f"⛔ Unauthorized request from {request.remote_addr}")
        return jsonify({"error": "Unauthorized"}), 401

    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "Invalid JSON body"}), 400

    event_id = data.get("id", "?")

    # Idempotency check
    if any(e.get("id") == event_id for e in received_events):
        log.info(f"↩  Duplicate event {event_id} — ignoring")
        return jsonify({"status": "duplicate"}), 409

    received_events.append(data)

    # Pretty-print to console
    ts = data.get("timestamp", "no-timestamp")
    event_type = data.get("type", "unknown")
    log.info(f"📩 Event #{len(received_events)}  [{event_type}]  ts={ts}")

    # Print all fields except id/type/timestamp for readability
    extra = {k: v for k, v in data.items() if k not in ("id", "type", "timestamp")}
    if extra:
        log.info(f"   payload: {json.dumps(extra, indent=2, ensure_ascii=False)}")

    return jsonify({"status": "ok", "received": len(received_events)}), 201


# ---------------------------------------------------------------------------
# Debug UI — list all received events
# ---------------------------------------------------------------------------

@app.route("/events", methods=["GET"])
def list_events():
    """Returns all received events as JSON. No auth required (debug only)."""
    return jsonify({
        "count": len(received_events),
        "events": received_events,
    })


@app.route("/events", methods=["DELETE"])
def clear_events():
    """Clears the in-memory event list."""
    received_events.clear()
    log.info("🗑  Event log cleared")
    return jsonify({"status": "cleared"})


@app.route("/", methods=["GET"])
def index():
    """Simple status page."""
    return (
        f"<h2>WatchLogger Debug Server</h2>"
        f"<p>Running · {len(received_events)} events received</p>"
        f"<p>Active nonces: {len(active_nonces)}</p>"
        f"<ul>"
        f"<li><a href='/events'>GET /events</a> — view all received events</li>"
        f"<li>DELETE /events — clear event log</li>"
        f"<li>GET /api/auth/pairing/request-nonce — generate pairing code</li>"
        f"<li>GET /pair/&lt;nonce&gt; — simulate user entering code</li>"
        f"</ul>"
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="WatchLogger Debug Server")
    parser.add_argument("--host",  default="0.0.0.0",    help="Bind host (default: 0.0.0.0)")
    parser.add_argument("--port",  default=8888,  type=int, help="Port (default: 8888)")
    parser.add_argument("--token", default="debug-token", help="Bearer token the Watch app must send")
    args = parser.parse_args()

    TOKEN = args.token
    app.config["PORT"] = args.port

    log.info("=" * 60)
    log.info("  WatchLogger Debug Server")
    log.info("=" * 60)
    log.info(f"  Listening on  http://{args.host}:{args.port}")
    log.info(f"  Auth token:   Bearer {TOKEN}")
    log.info(f"  Events log:   http://localhost:{args.port}/events")
    log.info("")
    log.info("  Watch app config:")
    log.info(f'    endpoint_url: "http://<your-ip>:{args.port}/api/logs"')
    log.info(f'    auth_header:  "Authorization"')
    log.info(f'    auth_token:   "Bearer {TOKEN}"')
    log.info("=" * 60)

    app.run(host=args.host, port=args.port, debug=False)
