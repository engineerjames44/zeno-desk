"""Zeno Desk live dashboard: a page on this Mac that shows the black box's numbers as they happen.

Run:  BOX=<box-ip> PHONE=<phone-ip> python3 tools/dashboard/server.py [port]     (default port 8790)
Then open http://localhost:8790. It passes through the box's /live, /stats and /control (fan and charging
test switch), and the phone's debug-build /stress, /llm and /metrics. Only fixed values are forwarded.
"""
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

BOX = os.environ.get("BOX", "zenodesk.local")
PHONE = os.environ.get("PHONE", "")
CHOICES = {"on", "off", "auto"}
HERE = os.path.dirname(os.path.abspath(__file__))
# Gesture training data lands here, one folder per label, ready for Create ML's Activity Classifier.
RECORDINGS = os.path.normpath(os.path.join(HERE, "..", "..", "ml", "recordings"))
LABELS = {"palm", "pinch", "swipe_left", "swipe_right", "none"}
SAFE_NAME = re.compile(r"^(palm|pinch|swipe_left|swipe_right|none)/[A-Za-z0-9_.-]+\.csv$")


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=HERE, **kwargs)

    def relay(self, url, method="GET"):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, method=method), timeout=3) as r:
                body, code = r.read(), 200
        except Exception as e:
            body, code = f'{{"error":"{type(e).__name__}"}}'.encode(), 502
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def save_recordings(self):
        """Copy any recordings the Mac doesn't have yet from the phone into ml/recordings/<label>/."""
        saved, total = 0, 0
        try:
            req = urllib.request.Request(f"http://{PHONE}:8080/recordings", method="POST")
            names = json.load(urllib.request.urlopen(req, timeout=5))
            for name in names:
                if not SAFE_NAME.match(name):
                    continue
                total += 1
                dest = os.path.join(RECORDINGS, *name.split("/"))
                if os.path.exists(dest):
                    continue
                req = urllib.request.Request(f"http://{PHONE}:8080/recfile?{urllib.parse.urlencode({'name': name})}", method="POST")
                body = urllib.request.urlopen(req, timeout=10).read()
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as f:
                    f.write(body)
                saved += 1
            body, code = json.dumps({"saved": saved, "total": total, "folder": "ml/recordings"}).encode(), 200
        except Exception as e:
            body, code = json.dumps({"error": type(e).__name__}).encode(), 502
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def allowed(self, post):
        """Only this dashboard's own page may use it. The Host check blocks DNS-rebinding tricks; for POSTs,
        browsers always send Origin, so a request from any other website (cross-site request forgery
        aimed at the fan, charging or stress switches) is refused."""
        mine = {f"localhost:{PORT}", f"127.0.0.1:{PORT}"}
        if self.headers.get("Host") not in mine:
            return False
        if post and self.headers.get("Origin") not in {f"http://{h}" for h in mine}:
            return False
        return True

    def do_GET(self):
        if not self.allowed(post=False):
            return self.send_error(403)
        if self.path in ("/api/live", "/api/stats"):
            return self.relay(f"http://{BOX}/{self.path[5:]}")
        super().do_GET()

    def do_POST(self):
        if not self.allowed(post=True):
            return self.send_error(403)
        url = urllib.parse.urlparse(self.path)
        query = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        if url.path == "/api/control":
            safe = {k: v for k, v in query.items() if k in ("fan", "charge") and v in CHOICES}
            return self.relay(f"http://{BOX}/control?{urllib.parse.urlencode(safe)}", "POST")
        if url.path == "/api/record" and PHONE:
            q = {}
            if query.get("label") in LABELS and query.get("secs", "").isdigit():
                q = {"label": query["label"], "secs": query["secs"]}
            if query.get("cancel") == "1":
                q = {"cancel": "1"}
            return self.relay(f"http://{PHONE}:8080/record?{urllib.parse.urlencode(q)}", "POST")
        if url.path == "/api/hand" and PHONE:
            return self.relay(f"http://{PHONE}:8080/hand", "POST")
        if url.path == "/api/save" and PHONE:
            return self.save_recordings()
        if url.path == "/api/metrics" and PHONE:
            return self.relay(f"http://{PHONE}:8080/metrics", "POST")
        if url.path == "/api/llm" and PHONE:
            on = {"1": "?on=1", "0": "?on=0"}.get(query.get("on"), "")
            return self.relay(f"http://{PHONE}:8080/llm{on}", "POST")
        if url.path == "/api/stress" and PHONE:
            on = {"1": "?on=1", "0": "?on=0"}.get(query.get("on"), "")
            return self.relay(f"http://{PHONE}:8080/stress{on}", "POST")
        self.send_error(404)

    def log_message(self, *args):
        pass


PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8790
port = PORT
print(f"Zeno Desk dashboard on http://localhost:{port}  (box: {BOX}, phone: {PHONE or "not set"})", flush=True)
ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
