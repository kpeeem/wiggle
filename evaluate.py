import argparse
import json
import shlex
from pathlib import Path

import cv2
import numpy as np
from skimage.metrics import structural_similarity

from wiggle import PRECONVERGED, ROOT, run_engine, shift

PHASES = [0.25, 0.5, 0.75]

parser = argparse.ArgumentParser()
parser.add_argument("--engines", nargs="+", default=["blend", "rife", "vt", "stereo"])
parser.add_argument("--scenes", nargs="+", default=["Aloe", "Art", "Baby1"])
parser.add_argument("--scales", type=float, nargs="+", default=[1.0, 0.5])
parser.add_argument("--out", type=Path, default=ROOT / "out" / "eval")
args = parser.parse_args()

results_path = args.out / "results.json"
rows = json.loads(results_path.read_text()) if results_path.exists() else []

for scene in args.scenes:
    for scale in args.scales:
        views = {}
        for index in range(1, 6):
            view = cv2.imread(str(ROOT / "data" / "middlebury" / scene / f"view{index}.png"), cv2.IMREAD_COLOR)
            views[index] = cv2.resize(view, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA) if scale != 1 else view
        truth = cv2.imread(str(ROOT / "data" / "middlebury" / scene / "disp1.png"), cv2.IMREAD_GRAYSCALE)
        convergence = round(float(np.median(truth[truth > 0])) * scale / 4) * 4

        base = args.out / f"{scene}_{scale:g}"
        base.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(base / "left.png"), views[1])
        cv2.imwrite(str(base / "right.png"), views[5])
        cv2.imwrite(str(base / "right_converged.png"), shift(views[5], convergence))

        for spec in args.engines:
            engine, _, extra = spec.partition(":")
            for variant in ["raw", "converged"] if engine in PRECONVERGED else ["raw"]:
                right = base / ("right.png" if variant == "raw" else "right_converged.png")
                out = base / f"{spec.replace(':', '_').replace(' ', '')}_{variant}"
                outputs = run_engine(engine, base / "left.png", right, PHASES, out, shlex.split(extra))
                timing = json.loads((out / "timing.json").read_text())
                rows = [r for r in rows if (r["scene"], r["scale"], r["engine"], r["variant"]) != (scene, scale, spec, variant)]
                for phase, path, frame_timing in zip(PHASES, outputs, timing["frames"]):
                    frame = cv2.imread(str(path), cv2.IMREAD_COLOR)
                    if variant == "converged":
                        frame = shift(frame, -phase * convergence)
                        cv2.imwrite(str(path), frame)
                    expected = views[1 + round(phase * 4)][:, convergence:-convergence]
                    actual = frame[:, convergence:-convergence]
                    error = np.mean((expected.astype(np.float64) - actual) ** 2)
                    rows.append({
                        "scene": scene,
                        "scale": scale,
                        "width": frame.shape[1],
                        "height": frame.shape[0],
                        "engine": spec,
                        "variant": variant,
                        "engine_variant": timing.get("variant"),
                        "phase": phase,
                        "psnr": float(10 * np.log10(255**2 / error)),
                        "ssim": float(structural_similarity(expected, actual, channel_axis=2)),
                        "frame_seconds": frame_timing["seconds"],
                        "setup_seconds": timing.get("load_seconds", 0) + timing.get("disparity_seconds", 0),
                    })
                results_path.write_text(json.dumps(rows, indent=1))

print(f"{'engine':34} {'variant':10} {'scale':>5} {'PSNR':>6} {'SSIM':>6} {'s/frame':>8} {'setup s':>8}")
for key in sorted({(r["engine"], r["variant"], r["scale"]) for r in rows}):
    group = [r for r in rows if (r["engine"], r["variant"], r["scale"]) == key]
    mean = lambda field: sum(r[field] for r in group) / len(group)
    print(f"{key[0]:34} {key[1]:10} {key[2]:>5g} {mean('psnr'):6.2f} {mean('ssim'):6.3f} {mean('frame_seconds'):8.3f} {mean('setup_seconds'):8.2f}")
