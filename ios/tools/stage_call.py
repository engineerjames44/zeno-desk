"""Plays a made-up call on the phone, the way the Pi will: ringing, live lines, ended, then clear.

Run:  python3 tools/stage_call.py <phone-ip>
"""
import json
import sys
import time
import urllib.request

if len(sys.argv) < 2:
    sys.exit("usage: python3 tools/stage_call.py <phone-ip>")
PHONE = sys.argv[1]
TO = "a restaurant"
SCRIPT = [
    ("zeno", "Hi, this is an AI assistant calling on behalf of James Cronin. I'd like to book a table for two this Wednesday at eight."),
    ("them", "Sure, let me check. Wednesday at eight... yes, we can do that."),
    ("zeno", "Great. Could you put it under the name James?"),
    ("them", "No problem. Table for two, Wednesday at eight, under James."),
    ("zeno", "Perfect, thank you very much. Bye now."),
]


def send(call):
    feed = {"v": 1, "items": [], "ticker": [], "live_call": call}
    req = urllib.request.Request(f"http://{PHONE}:8080/feed", json.dumps(feed).encode(),
                                 {"Content-Type": "application/json"}, method="POST")
    print(call["state"] if call else "clear", urllib.request.urlopen(req, timeout=5).status, flush=True)


send({"to": TO, "state": "ringing", "lines": []})
time.sleep(4)
lines = []
for who, text in SCRIPT:
    lines.append({"who": who, "text": text})
    send({"to": TO, "state": "live", "lines": lines})
    time.sleep(5)
send({"to": TO, "state": "ended", "lines": lines})
time.sleep(32)          # the ended call leaves the screen after 30 s by itself
send(None)              # and never leave test content on the desk
