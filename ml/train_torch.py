"""Zeno Desk gesture model, option B: a small 1D-CNN on Apple Vision hand points, trained in PyTorch.

Run:  ml/.venv/bin/python ml/train_torch.py
In:   ml/recordings/<label>/*.csv (from the dashboard), minus anything listed in ml/retired.txt
Out:  scores for the write-up (cross-validated by recording), the same scores for the phone's
      hand-written rules, and ml/zeno_gestures.pt (trained on everything).

How it's scored: 5-fold cross-validation where whole recordings are held out together, so every
recording is tested exactly once by a model that never saw it. Scored on 1-second windows (10 frames).
"""
import csv
import glob
import os
import random
from collections import Counter

import numpy as np
import torch
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.model_selection import StratifiedGroupKFold
from torch import nn

HERE = os.path.dirname(os.path.abspath(__file__))
LABELS = ["none", "palm", "pinch", "swipe_left", "swipe_right"]
MIRROR = {"swipe_left": "swipe_right", "swipe_right": "swipe_left"}
JOINTS = ["thumb_cmc", "thumb_mp", "thumb_ip", "thumb_tip", "index_mcp", "index_pip", "index_dip", "index_tip",
          "middle_mcp", "middle_pip", "middle_dip", "middle_tip", "ring_mcp", "ring_pip", "ring_dip", "ring_tip",
          "little_mcp", "little_pip", "little_dip", "little_tip"]
WINDOW = 10        # frames = 1 s at 10 fps
STRIDE = 3
NONE_STRIDE = 6    # "none" is long (17+ min): sample it more sparsely; class weights keep it fair
EPOCHS = 15
SEED = 7
random.seed(SEED); np.random.seed(SEED); torch.manual_seed(SEED)
torch.set_num_threads(2)   # keep the Mac usable while it trains


# ---------- data ----------

def retired():
    path = os.path.join(HERE, "retired.txt")
    out = set()
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#"):
                out |= set(glob.glob(os.path.join(HERE, "recordings", line)))
    return out


def load():
    """One entry per recording: label, name, and a [frames, features] array (no-hand frames kept as zeros)."""
    skip = retired()
    recs = []
    for label in LABELS:
        for path in sorted(glob.glob(os.path.join(HERE, "recordings", label, "*.csv"))):
            if path in skip:
                continue
            with open(path) as f:
                rows = list(csv.DictReader(f))
            recs.append({"label": label, "name": os.path.basename(path), "frames": frames(rows)})
    return recs


def frames(rows):
    """Per frame: hand (0/1), hand_x, hand_y, hand_dx, hand_dy, then 20 joints x,y relative to the wrist."""
    out, prev = [], None
    for r in rows:
        seen = r["hand"] == "1.0000"
        x, y = float(r["hand_x"]), float(r["hand_y"])
        dx = x - prev[0] if seen and prev else 0.0
        dy = y - prev[1] if seen and prev else 0.0
        joints = [float(r[f"{j}_{a}"]) for j in JOINTS for a in "xy"]
        out.append([1.0 if seen else 0.0, x if seen else 0.0, y if seen else 0.0, dx, dy] + joints)
        prev = (x, y) if seen else None
    return np.array(out, dtype=np.float32)


def windows(rec):
    """1-second windows. For gestures, only windows where the hand is seen in most frames
    (the hand dropping between repeats isn't the gesture); "none" keeps every window."""
    f = rec["frames"]
    out = []
    for start in range(0, len(f) - WINDOW + 1, NONE_STRIDE if rec["label"] == "none" else STRIDE):
        w = f[start:start + WINDOW]
        if rec["label"] != "none" and w[:, 0].mean() < 0.6:
            continue
        out.append(w)
    return out


# ---------- augmentation (training only) ----------

def mirrored(w):
    m = w.copy()
    seen = m[:, 0] > 0
    m[seen, 1] = 1 - m[seen, 1]          # hand_x
    m[:, 3] = -m[:, 3]                    # hand_dx
    m[:, 5::2] = -m[:, 5::2]              # every joint x
    return m


def augment(w, label, rng):
    out = [(w, label)]
    out.append((mirrored(w), MIRROR.get(label, label)))
    for base, lab in list(out):
        j = base.copy()
        j[:, 5:] += rng.normal(0, 0.03, j[:, 5:].shape).astype(np.float32) * (j[:, :1] > 0)
        out.append((j, lab))
    return out


# ---------- model ----------

class GestureNet(nn.Module):
    """Two 1D convolutions over time, then average over the window: about 25k weights."""
    def __init__(self, features, classes):
        super().__init__()
        self.net = nn.Sequential(
            nn.Conv1d(features, 64, 3, padding=1), nn.ReLU(), nn.Dropout(0.2),
            nn.Conv1d(64, 64, 3, padding=1), nn.ReLU(),
            nn.AdaptiveAvgPool1d(1), nn.Flatten(), nn.Linear(64, classes))

    def forward(self, x):                 # x: [batch, frames, features]
        return self.net(x.transpose(1, 2))


def train(X, y, epochs=EPOCHS):
    model = GestureNet(X.shape[2], len(LABELS))
    counts = np.bincount(y, minlength=len(LABELS)).astype(np.float32)
    weights = torch.tensor(counts.sum() / (len(LABELS) * np.maximum(counts, 1)))   # rarer classes count more
    loss_fn = nn.CrossEntropyLoss(weight=weights)
    opt = torch.optim.Adam(model.parameters(), lr=2e-3, weight_decay=1e-4)
    Xt, yt = torch.tensor(X), torch.tensor(y)
    for _ in range(epochs):
        model.train()
        for idx in torch.randperm(len(Xt)).split(64):
            opt.zero_grad()
            loss_fn(model(Xt[idx]), yt[idx]).backward()
            opt.step()
    return model.eval()


def build(recs, rng, augmented):
    X, y = [], []
    for rec in recs:
        for w in windows(rec):
            for ww, lab in (augment(w, rec["label"], rng) if augmented else [(w, rec["label"])]):
                X.append(ww); y.append(LABELS.index(lab))
    return np.stack(X), np.array(y)


# ---------- the phone's hand-written rules, scored on the same windows ----------

def rule(w):
    """Same logic as HandGestures.swift: swipe if the hand moves > 0.17 of the frame sideways within
    the window; pinch if thumb and index tips are within 0.25 hand-sizes; palm if all four
    fingertips are further from the wrist than their middle joints x 1.15. (No palm gate here.)"""
    seen = w[:, 0] > 0
    if seen.sum() >= 2:
        xs = w[seen, 1]
        lo, hi = xs.argmin(), xs.argmax()
        if xs[hi] - xs[lo] > 0.17:
            return "swipe_right" if hi > lo else "swipe_left"
    last = w[seen][-1] if seen.any() else None
    if last is None:
        return "none"
    p = {j: np.array(last[5 + 2 * i:7 + 2 * i]) for i, j in enumerate(JOINTS)}
    if np.linalg.norm(p["thumb_tip"] - p["index_tip"]) < 0.25:
        return "pinch"
    tips = ["index_tip", "middle_tip", "ring_tip", "little_tip"]
    pips = ["index_pip", "middle_pip", "ring_pip", "little_pip"]
    if all(np.linalg.norm(p[t]) > np.linalg.norm(p[b]) * 1.15 for t, b in zip(tips, pips)):
        return "palm"
    return "none"


# ---------- scoring ----------

def report(name, truth, pred):
    print(f"\n=== {name} ===")
    print(classification_report(truth, pred, labels=LABELS, digits=2, zero_division=0))
    cm = confusion_matrix(truth, pred, labels=LABELS)
    print("confusion (rows = what you did, columns = what it said):")
    print("              " + " ".join(f"{l[:11]:>11}" for l in LABELS))
    for l, row in zip(LABELS, cm):
        print(f"{l:>13} " + " ".join(f"{v:>11}" for v in row))
    none = [p for t, p in zip(truth, pred) if t == "none"]
    false = sum(1 for p in none if p != "none")
    print(f"false triggers: {false} of {len(none)} no-gesture windows ({100 * false / max(len(none), 1):.1f}%)")


def main():
    recs = load()
    print("recordings:", dict(Counter(r["label"] for r in recs)), flush=True)
    rng = np.random.default_rng(SEED)
    groups = np.arange(len(recs))
    labels = [r["label"] for r in recs]
    folds = StratifiedGroupKFold(n_splits=5, shuffle=True, random_state=SEED)

    truth, model_pred, rule_pred, wrong = [], [], [], Counter()
    for k, (tr, te) in enumerate(folds.split(np.zeros(len(recs)), labels, groups)):
        X, y = build([recs[i] for i in tr], rng, augmented=True)
        model = train(X, y)
        for i in te:
            ws = windows(recs[i])
            if not ws:
                continue
            with torch.no_grad():
                out = model(torch.tensor(np.stack(ws))).argmax(1).numpy()
            for w, o in zip(ws, out):
                truth.append(recs[i]["label"]); model_pred.append(LABELS[o]); rule_pred.append(rule(w))
                if LABELS[o] != recs[i]["label"]:
                    wrong[recs[i]["name"]] += 1
        print(f"fold {k + 1}/5 done ({len(X)} training windows incl. augmentation)", flush=True)

    report("YOUR MODEL (1D-CNN), cross-validated", truth, model_pred)
    report("HAND-WRITTEN RULES on the same windows (no palm gate)", truth, rule_pred)
    print("\nrecordings with the most model mistakes:", wrong.most_common(6))

    X, y = build(recs, rng, augmented=True)
    final = train(X, y)
    torch.save(final.state_dict(), os.path.join(HERE, "zeno_gestures.pt"))
    params = sum(p.numel() for p in final.parameters())
    print(f"\nfinal model trained on everything: {params:,} weights, saved ml/zeno_gestures.pt")


if __name__ == "__main__":
    main()
