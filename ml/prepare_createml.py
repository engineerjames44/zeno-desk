"""Turn the raw gesture recordings into Create ML Activity Classifier folders.

Run:  python3 ml/prepare_createml.py [--augment]
In:   ml/recordings/<label>/*.csv   (from the dashboard's "save to Mac"; never changed here)
Out:  ml/createml/train/<label>/*.csv and ml/createml/test/<label>/*.csv

- Gesture recordings lose the frames where no hand was seen (the hand dropping between repeats
  shouldn't teach the model that "no hand" means "palm"). "none" keeps every frame.
- Drops "which_hand" (Vision's left/right guess is unreliable while moving).
- Holds out recordings for testing, by whole recording: for each gesture the 5th and 10th
  (one per hand, as recorded 5 + 5), for "none" the last two. The model never trains on these.
- Adds motion features: hand_dx / hand_dy = how far the hand moved since the previous frame
  (0 when the hand wasn't seen in both). This makes a swipe's direction explicit.
- Recordings listed in ml/retired.txt are skipped entirely (kept on disk).
- --balance caps "none" in the training set at twice the median gesture's frames (random recordings,
  fixed seed), so the model isn't rewarded for always answering "nothing". Test set untouched.
- --augment adds made-up training recordings from the real ones (never to the test set):
  mirrored (left <-> right; a mirrored swipe left is labelled swipe right), a little jitter on
  every point, and 20% faster / slower playback.
"""
import csv
import glob
import os
import random
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "recordings")
OUT = os.path.join(HERE, "createml")
DROP = {"which_hand"}
AUGMENT = "--augment" in sys.argv
BALANCE = "--balance" in sys.argv
MIRROR_LABEL = {"swipe_left": "swipe_right", "swipe_right": "swipe_left"}


def with_motion(rows):
    """hand_dx, hand_dy: movement since the previous frame, in frame widths (0 across gaps)."""
    out, prev = [], None
    for r in rows:
        m = dict(r)
        seen = r["hand"] == "1.0000"
        if seen and prev is not None:
            m["hand_dx"] = f"{float(r['hand_x']) - float(prev['hand_x']):.4f}"
            m["hand_dy"] = f"{float(r['hand_y']) - float(prev['hand_y']):.4f}"
        else:
            m["hand_dx"] = m["hand_dy"] = "0.0000"
        prev = r if seen else None
        out.append(m)
    return out


def mirrored(rows):
    """Flip left and right: hand_x -> 1 - hand_x, every relative x -> -x."""
    out = []
    for r in rows:
        m = dict(r)
        for k, v in r.items():
            if k == "hand_x" and r["hand"] == "1.0000":
                m[k] = f"{1 - float(v):.4f}"
            elif (k.endswith("_x") and k != "hand_x") or k == "hand_dx":
                m[k] = f"{-float(v):.4f}"
        out.append(m)
    return out


def jittered(rows, rng, sigma=0.03):
    """A slightly shaky hand: small random noise on every joint (in hand-size units)."""
    out = []
    for r in rows:
        m = dict(r)
        if r["hand"] == "1.0000":
            for k, v in r.items():
                if (k.endswith("_x") or k.endswith("_y")) and not k.startswith(("hand_", "wrist_")):
                    m[k] = f"{float(v) + rng.gauss(0, sigma):.4f}"
        out.append(m)
    return out


def resampled(rows, speed):
    """Played faster (speed > 1, frames dropped) or slower (speed < 1, frames repeated)."""
    n = int(len(rows) / speed)
    out = [dict(rows[min(int(i * speed), len(rows) - 1)]) for i in range(n)]
    for i, r in enumerate(out):
        r["t"] = f"{float(rows[0]['t']) + i * 0.1:.3f}"
    return out   # "t" (time) stays first: Create ML expects it; it is not used as a feature


def test_files(label, files):
    """Held out for testing: for "none" the last two; for a gesture the last recording of each half
    (recordings are made one hand, then the other, so that's one per hand)."""
    if label == "none":
        return set(files[-2:])
    return {files[len(files) // 2 - 1], files[-1]} if len(files) >= 4 else set(files[-1:])


def retired():
    """Globs from ml/retired.txt: recordings kept on disk but left out of training and testing."""
    path = os.path.join(HERE, "retired.txt")
    if not os.path.exists(path):
        return set()
    out = set()
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#"):
            out |= set(glob.glob(os.path.join(SRC, line)))
    return out


RETIRED = set()


def main():
    global RETIRED
    RETIRED = retired()
    shutil.rmtree(OUT, ignore_errors=True)
    print(f"{'gesture':12} {'train files':>11} {'train s':>8} {'test files':>10} {'test s':>7}")
    for label in sorted(os.listdir(SRC)):
        files = sorted(set(glob.glob(os.path.join(SRC, label, "*.csv"))) - RETIRED)
        if not files:
            continue
        held = test_files(label, files)
        stats = {"train": [0, 0], "test": [0, 0]}
        for path in files:
            split = "test" if path in held else "train"
            with open(path) as f:
                rows = with_motion(list(csv.DictReader(f)))   # before dropping no-hand frames: gaps reset motion
            if label != "none":
                rows = [r for r in rows if r["hand"] == "1.0000"]
            if len(rows) < 10:          # under a second of hand: nothing to learn from
                continue
            cols = [c for c in rows[0] if c not in DROP]
            name = os.path.basename(path)[:-4]
            versions = [(label, name, rows)]
            if AUGMENT and split == "train":
                rng = random.Random(name)
                mirror = mirrored(rows)
                versions += [(MIRROR_LABEL.get(label, label), name + "_mirror", mirror),
                             (label, name + "_jitter", jittered(rows, rng)),
                             (MIRROR_LABEL.get(label, label), name + "_mirror_jitter", jittered(mirror, rng)),
                             (label, name + "_fast", resampled(rows, 1.2)),
                             (label, name + "_slow", resampled(rows, 0.8))]
            for out_label, out_name, out_rows in versions:
                dest = os.path.join(OUT, split, out_label)
                os.makedirs(dest, exist_ok=True)
                with open(os.path.join(dest, out_name + ".csv"), "w", newline="") as f:
                    w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore", lineterminator="\n")   # plain \n: Create ML misreads \r\n
                    w.writeheader()
                    w.writerows(out_rows)
                stats[split][0] += 1
                stats[split][1] += len(out_rows)
        print(f"{label:12} {stats['train'][0]:>11} {stats['train'][1] / 10:>8.0f} {stats['test'][0]:>10} {stats['test'][1] / 10:>7.0f}")
    if BALANCE:
        balance()
    print(f"\nWritten to {OUT}" + ("  (training set augmented)" if AUGMENT else "") + ("  (none balanced)" if BALANCE else ""))


def frames(path):
    with open(path) as f:
        return sum(1 for _ in f) - 1


def balance():
    """Drop random "none" training recordings until none is at most 2x the median gesture."""
    train = os.path.join(OUT, "train")
    sizes = {label: sum(frames(p) for p in glob.glob(os.path.join(train, label, "*.csv")))
             for label in os.listdir(train) if not label.startswith(".")}
    gestures = sorted(v for k, v in sizes.items() if k != "none")
    cap = 2 * gestures[len(gestures) // 2]
    files = sorted(glob.glob(os.path.join(train, "none", "*.csv")))
    random.Random(7).shuffle(files)
    total = sizes["none"]
    for path in files:
        if total <= cap:
            break
        total -= frames(path)
        os.remove(path)
    print(f"balanced: none {sizes['none'] / 10:.0f} s -> {total / 10:.0f} s (cap {cap / 10:.0f} s)")


if __name__ == "__main__":
    main()
