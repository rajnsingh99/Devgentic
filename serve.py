#!/usr/bin/env python3
"""Local preview server for the site. Unlike `python3 -m http.server` it sends no-store headers,
so a browser never shows a stale stylesheet or script after an edit. Not used in production."""
import http.server, socketserver, sys

class NoCache(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, max-age=0")
        super().end_headers()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", port), NoCache) as httpd:
    print(f"Serving on http://localhost:{port}/ (no-cache)")
    httpd.serve_forever()
