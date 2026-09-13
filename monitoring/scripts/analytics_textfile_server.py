#!/usr/bin/env python3
"""
analytics_textfile_server.py — Serve /var/lib/prometheus-textfiles/*.prom as
a single Prometheus /metrics endpoint on 127.0.0.1:9400.

Prometheus scrapes this instead of reading files directly, so the standard
Prometheus scrape model works without needing node_exporter running.
Concatenates all .prom files in the textfile directory on each request.
"""
import http.server
import os
import glob
import sys

TEXTFILE_DIR = "/var/lib/prometheus-textfiles"
PORT = 9400
BIND = "127.0.0.1"


class TextfileHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress access log noise

    def do_GET(self):
        if self.path not in ("/metrics", "/metrics/"):
            self.send_response(404)
            self.end_headers()
            return
        parts = []
        for path in sorted(glob.glob(os.path.join(TEXTFILE_DIR, "*.prom"))):
            try:
                with open(path) as f:
                    parts.append(f.read())
            except OSError:
                pass
        body = "\n".join(parts).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    server = http.server.HTTPServer((BIND, PORT), TextfileHandler)
    print(f"Serving {TEXTFILE_DIR}/*.prom at http://{BIND}:{PORT}/metrics")
    sys.stdout.flush()
    server.serve_forever()
