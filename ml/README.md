# Zeno Desk gestures: the ML

Touch-free control for the desk phone: the front camera watches for an open palm (wake), a pinch, and swipes
left and right. Apple Vision finds 21 hand points per frame on the phone; a small model trained here turns one
second of those points into a gesture. Only numbers are recorded, never images, and nothing leaves the phone
except the training recordings copied to the Mac.

## Pipeline

1. **Record** labelled hand points from the dashboard (`tools/dashboard`, "Train gestures"): one CSV per
   recording in `ml/recordings/<label>/` (kept out of git).
2. **Look** at them in the viewer: `python3 ml/make_viewer.py`, then open `ml/viewer/index.html` (via any local
   web server). It replays each recording as a hand skeleton with its raw numbers.
3. **Baseline**: `python3 ml/prepare_createml.py --augment --balance` then `swift ml/train_createml.swift`
   (Create ML Activity Classifier).
4. **Own model**: `ml/.venv/bin/python ml/train_torch.py`: a 1D-CNN (about 21k weights) on 1-second windows,
   with mirror and jitter augmentation, class weights, and motion features (hand_dx, hand_dy). Scored with
   5-fold cross-validation that holds out whole recordings, next to the phone's hand-written rules.
5. **Convert**: `ml/.venv/bin/python ml/convert_coreml.py` → `ml/ZenoGestures.mlmodel`, copied to
   `ios/ZenoCompanion/Models/`. Checked against PyTorch on real windows: same answers, 0.15 ms per decision.

`ml/retired.txt` lists recordings left out (the first swipe round included each swipe's return stroke).

## Results (14 Nov 2026, 63 recordings)

| | Own model (1D-CNN) | Hand-written rules | Create ML baseline |
|---|---|---|---|
| Accuracy, 1 s windows | **96%** | 59% | 86% (2 test recordings per gesture) |
| False triggers during normal desk use | **4.9%** | 37.4% | 10% |
| Size | 21,381 weights, 87 KB | – | – |

On the iPhone 12 Pro the whole app went from about 7% to 7.5–8% CPU with the model running at 10 fps.
The palm gate (gestures only count for 4 s after an open palm) sits on top, so real false triggers are lower.

## Lessons

- Class imbalance: lots of "no gesture" made the first models answer "nothing"; class weights fixed it.
- Data beats tuning: swipe recordings that included the return stroke taught the model the wrong direction.
- Small test sets lie: scoring on two recordings per gesture swung results between 0% and 100%;
  cross-validation over every recording gave stable numbers.
