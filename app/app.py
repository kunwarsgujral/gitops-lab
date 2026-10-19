"""Tiny demo service exposing RED metrics (Rate, Errors, Duration) to Prometheus on /metrics.

Failure injection for alerting drills (set through the Helm chart's app.* values):
  ERROR_RATE        fraction of "/" requests that return HTTP 500 (0.0 to 1.0, default 0)
  EXTRA_LATENCY_MS  random extra latency added to "/" requests, 0..N ms (default 0)
"""
import os
import random
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

# prometheus_client appends "_total", so this is exported as demo_app_http_requests_total.
# Labels stay low-cardinality on purpose: a fixed path set, never the raw URL.
REQUESTS = Counter("demo_app_http_requests", "HTTP requests handled", ["path", "code"])
LATENCY = Histogram(
    "demo_app_http_request_duration_seconds",
    "HTTP request latency",
    ["path"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)

PORT = int(os.environ.get("PORT", "8080"))
ERROR_RATE = float(os.environ.get("ERROR_RATE", "0"))
EXTRA_LATENCY_MS = int(os.environ.get("EXTRA_LATENCY_MS", "0"))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            self._send(200, generate_latest(), CONTENT_TYPE_LATEST)
        elif self.path == "/healthz":
            self._send(200, b"ok\n")
        elif self.path == "/":
            start = time.perf_counter()
            if EXTRA_LATENCY_MS:
                time.sleep(random.uniform(0, EXTRA_LATENCY_MS) / 1000)
            if random.random() < ERROR_RATE:
                code, body = 500, b"injected error\n"
            else:
                has_key = "yes" if os.environ.get("API_KEY") else "no"
                code, body = 200, f"hello (API_KEY injected: {has_key})\n".encode()
            self._send(code, body)
            LATENCY.labels(path="/").observe(time.perf_counter() - start)
            REQUESTS.labels(path="/", code=str(code)).inc()
        else:
            # Unknown paths 404 (so a smoke test pointed at the wrong path really fails).
            # Counted under one "other" label value to keep cardinality bounded.
            self._send(404, b"not found\n")
            REQUESTS.labels(path="other", code="404").inc()

    def _send(self, code, body, content_type="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # keep container logs quiet under load
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
