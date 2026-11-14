"""Stand-in for the ESP32 black box: prints each phone message and replies with fake /stats.

Run:  python3 tools/fake_box.py [port] [--v3]     (default 8080; --v3 = old firmware without /live)
Then set the phone's address to http://<this Mac's IP>:<port>/telemetry
"""
import json
import math
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

START = time.time()
last_phone = None
modes = {"fan": "auto", "charge": "auto"}
last_heard = None


def stats():
    phone = None
    if last_phone is not None:
        phone = {**last_phone, "age_s": int(time.time() - last_heard)}
    return {"v": 1, "relay": "charging", "fan": False,
            "bus_v": 5.08, "current_ma": 912, "power_mw": 4633,
            "temp_max_c": 31.4, "temp_avg_c": None, "ambient_c": 22.1,
            "phone": phone, "uptime_s": int(time.time() - START), "rssi": -58}


def live():
    """Firmware v4 /live: wavy made-up numbers, a new sample every 100 ms."""
    t = time.time() - START
    temp = 35 + 4 * math.sin(t / 20)
    fan = temp > 37 if modes["fan"] == "auto" else modes["fan"] == "on"
    charging = math.sin(t / 45) > 0 if modes["charge"] == "auto" else modes["charge"] == "on"
    current = (900 + 60 * math.sin(t * 1.3)) if charging else 2
    return {"v": 1, "n": int(t * 10), "ms": int(t * 1000), "relay": "charging" if charging else "off", "fan": fan,
            "charge_mode": modes["charge"], "fan_mode": modes["fan"],
            "bus_v": round(5.08 - current / 9000, 3), "current_ma": round(current, 1),
            "power_mw": round(current * 5.0, 1), "temp_c": round(temp, 2), "ambient_c": 21.4, "phone_battery": 57}


class Box(BaseHTTPRequestHandler):
    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        global last_phone, last_heard
        if self.path.startswith("/control"):
            from urllib.parse import parse_qs, urlparse
            for key, values in parse_qs(urlparse(self.path).query).items():
                if key in modes and values[0] in ("on", "off", "auto"):
                    modes[key] = values[0]
            print(time.strftime("%H:%M:%S"), "control", modes, flush=True)
            self.reply(live())
            return
        if self.path != "/telemetry":
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        last_phone, last_heard = json.loads(body), time.time()
        print(time.strftime("%H:%M:%S"), self.client_address[0], body.decode(), flush=True)
        self.reply(stats())

    def do_GET(self):
        if self.path == "/live" and not OLD_FIRMWARE:
            self.reply(live())
            return
        if self.path != "/stats":
            self.send_error(404)
            return
        self.reply(stats())

    def log_message(self, *args):
        pass


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
OLD_FIRMWARE = "--v3" in sys.argv   # pretend to be firmware v3: no /live
print(f"fake box listening on :{port}", flush=True)
HTTPServer(("0.0.0.0", port), Box).serve_forever()
