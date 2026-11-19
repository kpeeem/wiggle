import argparse
import json
import subprocess
from pathlib import Path

import cv2
import numpy as np

from stereo import background_columns

HERE = Path(__file__).resolve().parent
DATA = HERE.parent.parent / "data" / "middlebury"
TRUE_VIEW = {0.25: 2, 0.5: 3, 0.75: 4}


def psnr(frame, truth):
    return float(10 * np.log10(255**2 / np.mean((frame.astype(np.float64) - truth.astype(np.float64)) ** 2)))


def run(out, left, right, phases, extra):
    command = [str(HERE / "run"), str(left), str(right), "--phases", *map(str, phases), "--out", str(out), *extra]
    subprocess.run(command, check=True)
    return json.loads((out / "timing.json").read_text())


def seconds(timing):
    warp = float(np.mean([frame["seconds"] for frame in timing["frames"]]))
    return {key: timing[key] for key in ("load_seconds", "warmup_seconds", "disparity_seconds")} | {"warp_seconds": warp}


parser = argparse.ArgumentParser()
parser.add_argument("--scenes", nargs="+", default=["Aloe", "Art", "Baby1"])
parser.add_argument("--matchers", nargs="+", default=["sgbm", "neural"])
parser.add_argument("--out", type=Path, default=HERE / "out" / "bench")
arguments = parser.parse_args()

results = {}
for scene in arguments.scenes:
    views = {index: cv2.imread(str(DATA / scene / f"view{index}.png")) for index in range(1, 6)}
    out = arguments.out / scene
    out.mkdir(parents=True, exist_ok=True)
    truth = {}
    for side, index in (("left", 1), ("right", 5)):
        truth[side] = cv2.imread(str(DATA / scene / f"disp{index}.png"), cv2.IMREAD_UNCHANGED).astype(np.float32)
        filled = np.take_along_axis(truth[side], background_columns(truth[side], truth[side] > 0), 1)
        cv2.imwrite(str(out / f"truth_{side}.png"), (filled * 64).astype(np.uint16))
    height, width = truth["left"].shape
    columns = np.arange(width, dtype=np.float32)[None]
    rows = np.repeat(np.arange(height, dtype=np.float32)[:, None], width, 1)
    unoccluded = {}
    for side, other, direction in (("left", "right", -1), ("right", "left", 1)):
        seen = cv2.remap(truth[other], columns + direction * truth[side], rows, cv2.INTER_NEAREST)
        unoccluded[side] = (truth[side] > 0) & (seen > 0) & (np.abs(seen - truth[side]) <= 1)

    sources = {matcher: ["--matcher", matcher] for matcher in arguments.matchers}
    if "neural" in sources:
        sources["neural-quarter"] = ["--matcher", "neural", "--match-megapixels", "0.4"]
    sources["truth"] = ["--disparity-left", str(out / "truth_left.png"), "--disparity-right", str(out / "truth_right.png")]
    entry = {"psnr": {}, "accuracy": {}, "full": {}, "half": {}, "psnr_half": {}, "psnr_pair13": {}}
    entry["psnr"]["blend"] = {
        phase: psnr((1 - phase) * views[1] + phase * views[5], views[index]) for phase, index in TRUE_VIEW.items()
    }
    entry["psnr_pair13"]["blend"] = psnr(0.5 * views[1] + 0.5 * views[3], views[2])
    half = {index: cv2.resize(view, None, fx=0.5, fy=0.5, interpolation=cv2.INTER_AREA) for index, view in views.items()}
    for index in (1, 5):
        cv2.imwrite(str(out / f"half_view{index}.png"), half[index])

    for name, extra in sources.items():
        timing = run(out / name, DATA / scene / "view1.png", DATA / scene / "view5.png", TRUE_VIEW, extra)
        entry["full"][name] = seconds(timing) | {"variant": timing["variant"]}
        entry["psnr"][name] = {
            phase: psnr(cv2.imread(str(out / name / f"frame_{phase:.3f}.png")), views[index])
            for phase, index in TRUE_VIEW.items()
        }
        if name == "truth":
            continue
        entry["accuracy"][name] = {}
        for side in ("left", "right"):
            estimate = cv2.imread(str(out / name / f"disparity_{side}.png"), cv2.IMREAD_UNCHANGED) / 64
            error = np.abs(estimate - truth[side])
            for label, mask in (("known", truth[side] > 0), ("unoccluded", unoccluded[side])):
                entry["accuracy"][name][f"{side}_{label}"] = {
                    "mean_error": float(error[mask].mean()),
                    "bad2_percent": float((error[mask] > 2).mean() * 100),
                }
        if name not in arguments.matchers:
            continue
        run(out / f"{name}_pair13", DATA / scene / "view1.png", DATA / scene / "view3.png", [0.5], extra)
        entry["psnr_pair13"][name] = psnr(cv2.imread(str(out / f"{name}_pair13" / "frame_0.500.png")), views[2])
        timing = run(out / f"{name}_half", out / "half_view1.png", out / "half_view5.png", [0.5], extra)
        entry["half"][name] = seconds(timing)
        entry["psnr_half"][name] = psnr(cv2.imread(str(out / f"{name}_half" / "frame_0.500.png")), half[3])
    results[scene] = entry

(arguments.out / "results.json").write_text(json.dumps(results, indent=2))
names = [*results[arguments.scenes[0]]["full"], "blend"]
print("\nPSNR, pair 1/5, dB\nscene phase " + " ".join(names))
for scene, entry in results.items():
    for phase in TRUE_VIEW:
        print(scene, phase, " ".join(f"{entry['psnr'][name][phase]:.2f}" for name in names))
print("\nPSNR, pair 1/3 at 0.5 against view2, dB\nscene " + " ".join([*arguments.matchers, "blend"]))
for scene, entry in results.items():
    print(scene, " ".join(f"{entry['psnr_pair13'][name]:.2f}" for name in [*arguments.matchers, "blend"]))
print("\nmatcher error against truth: mean px / share above 2 px, %")
for scene, entry in results.items():
    for name, sides in entry["accuracy"].items():
        print(scene, name, " ".join(f"{key}={value['mean_error']:.2f}/{value['bad2_percent']:.1f}" for key, value in sides.items()))
print("\nseconds: size matcher load warmup disparity warp-per-frame")
for scene, entry in results.items():
    for size in ("full", "half"):
        for name, timing in entry[size].items():
            print(scene, size, name, " ".join(f"{timing[key]:.2f}" for key in ("load_seconds", "warmup_seconds", "disparity_seconds", "warp_seconds")))
print("\nPSNR at half size, phase 0.5, dB")
for scene, entry in results.items():
    print(scene, " ".join(f"{name}={value:.2f}" for name, value in entry["psnr_half"].items()))
