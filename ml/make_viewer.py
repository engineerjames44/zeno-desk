"""Build the gesture data viewer's data file from real recordings.

Run:  python3 ml/make_viewer.py
Reads ml/recordings/<label>/*.csv and writes ml/viewer/data.js (two recordings per gesture,
one from each half, i.e. one per hand as recorded). Open ml/viewer/index.html to see them.
"""
import csv
import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
out = {}
for label in ["palm", "pinch", "swipe_left", "swipe_right", "none"]:
    files = sorted(glob.glob(os.path.join(HERE, "recordings", label, "*.csv")))
    picks = [files[0], files[len(files) // 2]] if len(files) > 1 else files
    out[label] = []
    for path in picks:
        with open(path) as f:
            reader = csv.reader(f)
            header = next(reader)
            rows = [[round(float(v), 4) for v in r] for r in reader]
        out[label].append({"file": f"{label}/{os.path.basename(path)}", "header": header, "rows": rows})
with open(os.path.join(HERE, "viewer", "data.js"), "w") as f:
    f.write("const RECORDINGS = " + json.dumps(out, separators=(",", ":")) + ";\n")
print("wrote ml/viewer/data.js:", {k: [len(r["rows"]) for r in v] for k, v in out.items()})
