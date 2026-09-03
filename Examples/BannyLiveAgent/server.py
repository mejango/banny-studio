#!/usr/bin/env python3
"""Tiny reference implementation of the banny.agent.v1 localhost API.

This is deliberately a deterministic toy, not an AI. Replace `decide` with a
call to the participant's model while keeping the HTTP contract unchanged.
"""

from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json

HOST = "127.0.0.1"
PORT = 7331
MAX_REQUEST_BYTES = 256 * 1024


def decide(request):
    seed = int.from_bytes(sha256(request["request_id"].encode()).digest()[:2], "big")
    directions = ("left", "right")
    actions = [
        {
            "op": "move",
            "direction": directions[seed % len(directions)],
            "duration_ms": 320,
        }
    ]
    if seed % 3 == 0:
        actions.append({"op": "expression", "expression": "brow1", "duration_ms": 100})
    response = {
        "protocol": "banny.agent.v1",
        "request_id": request["request_id"],
        "intent_id": f"toy-{request['request_id']}",
        "actions": actions,
        "request_after_ms": 1800,
    }
    if seed % 4 == 0:
        response["say"] = "I am the reference bot. Replace me with your local AI."
    return response


class Handler(BaseHTTPRequestHandler):
    server_version = "BannyReferenceAgent/1"

    def do_POST(self):
        if self.path != "/v1/decide":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.send_error(413)
            return
        try:
            request = json.loads(self.rfile.read(length))
            if request.get("protocol") != "banny.agent.v1" or not request.get("request_id"):
                raise ValueError("unsupported request")
            body = json.dumps(decide(request), separators=(",", ":")).encode()
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            self.send_error(422)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, pattern, *args):
        print(pattern % args)


if __name__ == "__main__":
    print(f"Banny reference agent listening at http://{HOST}:{PORT}/v1/decide")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
