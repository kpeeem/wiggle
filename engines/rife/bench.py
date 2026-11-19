import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

here = Path(__file__).resolve().parent
data = here.parent.parent / "data" / "middlebury"
work = here / "out" / "bench"
pairs = {"1/5": (1, 5, {0.25: 2, 0.5: 3, 0.75: 4}), "1/3": (1, 3, {0.5: 2})}
scales = [float(value) for value in sys.argv[1:]] or [0.125, 0.25, 0.5, 1.0, 2.0]


def psnr(a, b):
    difference = np.asarray(a, dtype=np.float64) - np.asarray(b, dtype=np.float64)
    return 10 * np.log10(255 ** 2 / np.mean(difference ** 2))


rows = []
for scene in ["Aloe", "Art", "Baby1"]:
    for pair, (left_index, right_index, truths) in pairs.items():
        for shrink in [1, 2, 4]:
            views = {}
            for index in [left_index, right_index, *truths.values()]:
                full = Image.open(data / scene / f"view{index}.png").convert("RGB")
                small = full.resize((full.width // shrink, full.height // shrink), Image.LANCZOS)
                path = work / "inputs" / f"{scene}_{shrink}_view{index}.png"
                path.parent.mkdir(parents=True, exist_ok=True)
                small.save(path)
                views[index] = (path, small, full)
            left, right = views[left_index][1], views[right_index][1]
            for scale in scales:
                out = work / f"{scene}_{left_index}{right_index}_shrink{shrink}_scale{scale:g}"
                phases = [f"{phase:g}" for phase in truths]
                subprocess.run(
                    [here / "run", views[left_index][0], views[right_index][0],
                     "--phases", *phases, "--out", out, "--scale", f"{scale:g}"],
                    check=True,
                )
                timing = json.loads((out / "timing.json").read_text())
                for frame, (phase, truth_index) in zip(timing["frames"], truths.items()):
                    _, truth_small, truth_full = views[truth_index]
                    made = Image.open(out / f"frame_{phase:.3f}.png")
                    assert made.size == left.size and made.mode == "RGB"
                    row = {
                        "scene": scene, "pair": pair, "phase": phase, "shrink": shrink, "scale": scale,
                        "width": made.width, "height": made.height,
                        "seconds": frame["seconds"],
                        "load_seconds": timing["load_seconds"],
                        "warmup_seconds": timing["warmup_seconds"],
                        "psnr": psnr(made, truth_small),
                        "psnr_blend": psnr(Image.blend(left, right, phase), truth_small),
                        "psnr_upscaled_vs_full": psnr(made.resize(truth_full.size, Image.BICUBIC), truth_full),
                    }
                    rows.append(row)
                    print("\t".join(f"{value:.3f}" if isinstance(value, float) else str(value) for value in row.values()), flush=True)

(work / "results.json").write_text(json.dumps(rows, indent=2))
