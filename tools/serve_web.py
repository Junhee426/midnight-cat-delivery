#!/usr/bin/env python3
"""Serve builds/web under a GitHub-Pages-like sub-path on localhost.

    python3 tools/serve_web.py            # http://localhost:8060/midnight-cat-delivery/
    python3 tools/serve_web.py --port 9000 --prefix /my-repo/

Only for local testing (HTTP on localhost). No cross-origin isolation headers are sent,
matching GitHub Pages, so this also checks that the single-threaded build starts without them.
"""
import argparse
import functools
import http.server
import pathlib

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8060)
ap.add_argument("--prefix", default="/midnight-cat-delivery/")
ap.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parent.parent / "builds" / "web"))
args = ap.parse_args()
root = pathlib.Path(args.root).resolve()
prefix = "/" + args.prefix.strip("/") + "/"


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      ".wasm": "application/wasm", ".js": "text/javascript", ".pck": "application/octet-stream"}

    def translate_path(self, path):
        p = path.split("?", 1)[0].split("#", 1)[0]
        if not p.startswith(prefix):
            return str(root / "__not_found__")
        return super().translate_path("/" + p[len(prefix):])

    def do_GET(self):
        if self.path.rstrip("/") + "/" == prefix and not self.path.endswith("/"):
            self.send_response(301)
            self.send_header("Location", prefix)
            self.end_headers()
            return
        super().do_GET()


if not (root / "index.html").exists():
    raise SystemExit(f"{root}/index.html not found - run tools/build_web.sh first")
server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), functools.partial(Handler, directory=str(root)))
print(f"Serving {root} at http://localhost:{args.port}{prefix}")
server.serve_forever()
