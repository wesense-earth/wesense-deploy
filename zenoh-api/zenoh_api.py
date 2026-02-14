#!/usr/bin/env python3
"""
WeSense Zenoh API — HTTP Frontend for Distributed Queries

Translates REST requests into Zenoh distributed queries, collects
results from all responding queryables, deduplicates, and returns
aggregated JSON.

Endpoints:
    GET /api/p2p/summary  — Hourly aggregates from all stations
    GET /api/p2p/latest   — Latest readings, deduped by (device_id, reading_type)
    GET /api/p2p/history  — Historical readings (hours=N parameter)
    GET /api/p2p/devices  — Device list, deduped by device_id
    GET /health           — Connection status

Usage:
    python zenoh_api.py
"""

import json
import logging
import os
import signal
import sys
import threading
import time

from flask import Flask, jsonify, request

from wesense_ingester import setup_logging
from wesense_ingester.zenoh.config import ZenohConfig

# ── Configuration ─────────────────────────────────────────────────────

QUERY_TIMEOUT = float(os.getenv("ZENOH_QUERY_TIMEOUT", "5.0"))
QUERY_KEY = os.getenv("ZENOH_QUERY_KEY", "wesense/v2/live/**")
FLASK_PORT = int(os.getenv("FLASK_PORT", "5100"))
FLASK_HOST = os.getenv("FLASK_HOST", "0.0.0.0")

logger = setup_logging("zenoh_api")

# ── Zenoh session management ─────────────────────────────────────────

_zenoh_session = None
_zenoh_lock = threading.Lock()


def get_zenoh_session():
    """Get or create the Zenoh session (lazy init)."""
    global _zenoh_session
    if _zenoh_session is not None:
        return _zenoh_session

    with _zenoh_lock:
        if _zenoh_session is not None:
            return _zenoh_session

        try:
            import zenoh
            config = ZenohConfig.from_env()
            z_config = zenoh.Config.from_json5(config.to_zenoh_json())
            _zenoh_session = zenoh.open(z_config)
            logger.info("Zenoh session opened (mode=%s)", config.mode)
            return _zenoh_session
        except Exception as e:
            logger.error("Failed to open Zenoh session: %s", e)
            return None


def close_zenoh_session():
    """Close the Zenoh session."""
    global _zenoh_session
    with _zenoh_lock:
        if _zenoh_session is not None:
            _zenoh_session.close()
            _zenoh_session = None
            logger.info("Zenoh session closed")


# ── Query helpers ─────────────────────────────────────────────────────

def zenoh_query(query_type, params=None):
    """Execute a Zenoh get() query and collect results from all queryables."""
    session = get_zenoh_session()
    if session is None:
        return {"error": "Zenoh session not available", "results": []}

    # Build query string
    query_str = query_type
    if params:
        param_parts = [f"{k}={v}" for k, v in params.items() if v is not None]
        if param_parts:
            query_str += "?" + "&".join(param_parts)

    try:
        replies = session.get(
            QUERY_KEY,
            parameters=query_str,
            timeout=QUERY_TIMEOUT,
        )

        results = []
        for reply in replies:
            try:
                if reply.ok:
                    payload = reply.ok.payload.to_bytes()
                    data = json.loads(payload)
                    if isinstance(data, dict) and "results" in data:
                        results.extend(data["results"])
                    elif isinstance(data, list):
                        results.extend(data)
            except Exception as e:
                logger.debug("Failed to parse query reply: %s", e)
                continue

        return {"results": results}

    except Exception as e:
        logger.error("Zenoh query failed: %s", e)
        return {"error": str(e), "results": []}


def dedup_by_keys(results, keys):
    """Deduplicate results by composite key."""
    seen = set()
    deduped = []
    for r in results:
        key = tuple(r.get(k, "") for k in keys)
        if key not in seen:
            seen.add(key)
            deduped.append(r)
    return deduped


# ── Flask app ─────────────────────────────────────────────────────────

app = Flask(__name__)
app.logger.setLevel(logging.WARNING)


@app.route("/health", methods=["GET"])
def health():
    session = get_zenoh_session()
    return jsonify({
        "status": "healthy" if session is not None else "degraded",
        "zenoh_connected": session is not None,
    }), 200 if session is not None else 503


@app.route("/api/p2p/summary", methods=["GET"])
def p2p_summary():
    """Hourly aggregates from all stations."""
    result = zenoh_query("summary")
    return jsonify(result)


@app.route("/api/p2p/latest", methods=["GET"])
def p2p_latest():
    """Latest readings, deduped by (device_id, reading_type)."""
    result = zenoh_query("latest")
    result["results"] = dedup_by_keys(
        result["results"], ["device_id", "reading_type"]
    )
    return jsonify(result)


@app.route("/api/p2p/history", methods=["GET"])
def p2p_history():
    """Historical readings for the last N hours."""
    hours = request.args.get("hours", "6")
    result = zenoh_query("history", {"hours": hours})
    return jsonify(result)


@app.route("/api/p2p/devices", methods=["GET"])
def p2p_devices():
    """Device list, deduped by device_id."""
    result = zenoh_query("devices")
    result["results"] = dedup_by_keys(result["results"], ["device_id"])
    return jsonify(result)


# ── Main ──────────────────────────────────────────────────────────────

def shutdown_handler(signum=None, frame=None):
    logger.info("Shutting down...")
    close_zenoh_session()
    sys.exit(0)


def main():
    signal.signal(signal.SIGINT, shutdown_handler)
    signal.signal(signal.SIGTERM, shutdown_handler)

    logger.info("=" * 60)
    logger.info("WeSense Zenoh API (HTTP Query Frontend)")
    logger.info("Query key: %s | Timeout: %.1fs", QUERY_KEY, QUERY_TIMEOUT)
    logger.info("=" * 60)

    # Open Zenoh session eagerly
    get_zenoh_session()

    try:
        from waitress import serve
        logger.info("Starting on %s:%d (waitress)", FLASK_HOST, FLASK_PORT)
        serve(app, host=FLASK_HOST, port=FLASK_PORT, _quiet=True)
    except ImportError:
        logger.info("Starting on %s:%d (flask dev server)", FLASK_HOST, FLASK_PORT)
        app.run(host=FLASK_HOST, port=FLASK_PORT, use_reloader=False)


if __name__ == "__main__":
    main()
