import argparse
import json
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("--scale", type=float, default=1.0)
parser.add_argument("--quality", nargs="+", default=["normal", "quality"])
args = parser.parse_args()

here = Path(__file__).resolve().parent
data = here.parent.parent / "data" / "middlebury"
out = here / ".build" / "psnr" / f"scale{args.scale}"
cases = [(1, 5, {0.25: 2, 0.5: 3, 0.75: 4}), (1, 3, {0.5: 2})]


def psnr(a, b):
    return 10 * np.log10(255**2 / np.mean((a - b) ** 2))


print("scene size pair phase quality psnr blend seconds")
for scene in ["Aloe", "Art", "Baby1"]:
    views = {}
    for index in range(1, 6):
        image = Image.open(data / scene / f"view{index}.png").convert("RGB")
        size = (round(image.width * args.scale), round(image.height * args.scale))
        path = out / scene / f"view{index}.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        image.resize(size, Image.LANCZOS).save(path)
        views[index] = np.asarray(Image.open(path), dtype=np.float64)
    for left, right, truths in cases:
        for quality in args.quality:
            target = out / f"{scene}_{left}{right}_{quality}"
            subprocess.run(
                [here / "run", out / scene / f"view{left}.png", out / scene / f"view{right}.png",
                 "--phases", *map(str, truths), "--out", target, "--quality", quality],
                check=True,
            )
            seconds = {f["phase"]: f["seconds"] for f in json.loads((target / "timing.json").read_text())["frames"]}
            for phase, view in truths.items():
                frame = np.asarray(Image.open(target / f"frame_{phase:.3f}.png").convert("RGB"), dtype=np.float64)
                blend = np.round(views[left] * (1 - phase) + views[right] * phase)
                print(f"{scene} {size[0]}x{size[1]} {left}/{right} {phase} {quality} "
                      f"{psnr(frame, views[view]):.2f} {psnr(blend, views[view]):.2f} {seconds[phase]:.3f}")
