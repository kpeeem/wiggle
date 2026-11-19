import argparse
import json
import time
from pathlib import Path

import cv2

parser = argparse.ArgumentParser()
parser.add_argument("left")
parser.add_argument("right")
parser.add_argument("--phases", type=float, nargs="+", required=True)
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()

left = cv2.imread(args.left, cv2.IMREAD_COLOR)
right = cv2.imread(args.right, cv2.IMREAD_COLOR)
args.out.mkdir(parents=True, exist_ok=True)

frames = []
for phase in args.phases:
    started = time.perf_counter()
    frame = cv2.addWeighted(left, 1 - phase, right, phase, 0)
    frames.append({"phase": phase, "seconds": time.perf_counter() - started})
    cv2.imwrite(str(args.out / f"frame_{phase:.3f}.png"), frame)

timing = {
    "engine": "blend",
    "variant": "cross-fade",
    "width": left.shape[1],
    "height": left.shape[0],
    "load_seconds": 0,
    "frames": frames,
}
(args.out / "timing.json").write_text(json.dumps(timing, indent=2))
