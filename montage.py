import argparse
from pathlib import Path

import cv2
import numpy as np

from wiggle import ROOT

parser = argparse.ArgumentParser()
parser.add_argument("scene")
parser.add_argument("--runs", nargs="+", required=True, metavar="DIR=LABEL")
parser.add_argument("--scale", type=float, default=1.0)
parser.add_argument("--phase", type=float, default=0.5)
parser.add_argument("--crop", type=int, nargs=4, metavar=("X", "Y", "W", "H"), required=True)
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()

x, y, w, h = args.crop
truth = cv2.imread(str(ROOT / "data" / "middlebury" / args.scene / f"view{1 + round(args.phase * 4)}.png"), cv2.IMREAD_COLOR)
if args.scale != 1:
    truth = cv2.resize(truth, None, fx=args.scale, fy=args.scale, interpolation=cv2.INTER_AREA)
tiles = [("real photo", truth)]
for run in args.runs:
    directory, _, label = run.partition("=")
    path = ROOT / "out" / "eval" / f"{args.scene}_{args.scale:g}" / directory / f"frame_{args.phase:.3f}.png"
    tiles.append((label, cv2.imread(str(path), cv2.IMREAD_COLOR)))

columns = []
for label, image in tiles:
    header = np.full((44, w, 3), 255, np.uint8)
    cv2.putText(header, label, (2, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.75, (26, 26, 26), 2, cv2.LINE_AA)
    columns += [np.vstack([header, image[y:y + h, x:x + w]]), np.full((44 + h, 10, 3), 255, np.uint8)]
args.out.parent.mkdir(parents=True, exist_ok=True)
cv2.imwrite(str(args.out), np.hstack(columns[:-1]))
