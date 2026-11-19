import argparse
import json
import sys
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
from PIL import Image

here = Path(__file__).resolve().parent
sys.path.insert(0, str(here / "third_party" / "rife-mlx"))

from rife_mlx.utils.weights import build_model

parser = argparse.ArgumentParser()
parser.add_argument("left")
parser.add_argument("right")
parser.add_argument("--phases", type=float, nargs="+", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--scale", type=float, default=1.0, choices=[0.125, 0.25, 0.5, 1.0, 2.0])
args = parser.parse_args()

left = Image.open(args.left).convert("RGB")
right = Image.open(args.right).convert("RGB")
if left.size != right.size:
    sys.exit(f"size mismatch: {left.size} vs {right.size}")

started = time.perf_counter()
model = build_model("4.25", weights_dir=str(here / "weights"))
load_seconds = time.perf_counter() - started

tensors = [mx.array(np.asarray(image, dtype=np.float32)[None] / 255) for image in (left, right)]


def infer(phase):
    started = time.perf_counter()
    frame = model.inference(*tensors, phase, args.scale)
    mx.eval(frame)
    return frame, time.perf_counter() - started


_, warmup_seconds = infer(0.5)

out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
frames = []
for phase in args.phases:
    frame, seconds = infer(phase)
    pixels = (np.clip(np.array(frame)[0], 0, 1) * 255).round().astype(np.uint8)
    Image.fromarray(pixels).save(out / f"frame_{phase:.3f}.png")
    frames.append({"phase": phase, "seconds": seconds})

(out / "timing.json").write_text(json.dumps({
    "engine": "rife",
    "variant": f"mlx-4.25 scale={args.scale:g}",
    "width": left.width,
    "height": left.height,
    "load_seconds": load_seconds,
    "warmup_seconds": warmup_seconds,
    "frames": frames,
}, indent=2))
