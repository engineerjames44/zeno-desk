"""Convert the trained PyTorch gesture model (ml/zeno_gestures.pt) to Core ML for the phone.

Run:  ml/.venv/bin/python ml/convert_coreml.py
Out:  ml/ZenoGestures.mlmodel
Input "frames": [1, 10, 45] (1 s of hand-point frames, same columns as train_torch.frames()).
Output "probs": [1, 5] for none, palm, pinch, swipe_left, swipe_right.
Uses Core ML's older "neuralnetwork" format: it needs no native converter parts (not yet built for
this Python version) and runs on iOS 26 like any other Core ML model.
"""
import os
import sys

import coremltools as ct
import torch
from torch import nn

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from train_torch import LABELS, WINDOW, GestureNet  # noqa: E402

FEATURES = 45


class WithSoftmax(nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        return torch.softmax(self.net(x), dim=1)


net = GestureNet(FEATURES, len(LABELS))
net.load_state_dict(torch.load(os.path.join(HERE, "zeno_gestures.pt")))
model = WithSoftmax(net).eval()
example = torch.zeros(1, WINDOW, FEATURES)
traced = torch.jit.trace(model, example)

mlmodel = ct.convert(traced, convert_to="neuralnetwork", minimum_deployment_target=ct.target.iOS14,
                     inputs=[ct.TensorType(name="frames", shape=example.shape)])
spec = mlmodel.get_spec()
out_name = spec.description.output[0].name
ct.utils.rename_feature(spec, out_name, "probs")
mlmodel = ct.models.MLModel(spec)
mlmodel.author = "James Cronin"
mlmodel.short_description = "Zeno Desk hand gestures: 1D-CNN on 1 s of Apple Vision hand points. Classes: " + ", ".join(LABELS)
out = os.path.join(HERE, "ZenoGestures.mlmodel")
mlmodel.save(out)
print("saved", out, os.path.getsize(out), "bytes")
