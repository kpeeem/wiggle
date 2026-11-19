import argparse
import json
import sys
import time
from pathlib import Path

import cv2
import numpy as np

CONSISTENCY_TOLERANCE = 1.5
EDGE_TRIM = 1
HOLE_SMOOTHING = 9
NEURAL_MODEL = "11-33-40"
NEURAL_ITERATIONS = 16


def background_columns(disparity, valid):
    height, width = disparity.shape
    columns = np.broadcast_to(np.arange(width), (height, width))
    left = np.maximum.accumulate(np.where(valid, columns, -1), axis=1)
    right = np.minimum.accumulate(np.where(valid, columns, width)[:, ::-1], axis=1)[:, ::-1]
    left_value = np.where(left >= 0, np.take_along_axis(disparity, left.clip(0), 1), np.inf)
    right_value = np.where(right < width, np.take_along_axis(disparity, right.clip(None, width - 1), 1), np.inf)
    return np.where(left_value <= right_value, left, right).clip(0, width - 1)


def row_grid(shape):
    return np.repeat(np.arange(shape[0], dtype=np.float32)[:, None], shape[1], 1)


def verify(disparity, other, direction):
    width = disparity.shape[1]
    columns = np.arange(width, dtype=np.float32)[None]
    seen = cv2.remap(other, columns + direction * disparity, row_grid(disparity.shape), cv2.INTER_NEAREST, borderValue=-9)
    reliable = np.abs(seen - disparity) <= CONSISTENCY_TOLERANCE
    filled = np.take_along_axis(disparity, background_columns(disparity, reliable), 1)
    match = columns + direction * filled
    unseen = ~reliable & ((match < 0) | (match > width - 1))
    return np.where(unseen, filled, disparity), reliable


def sgbm_pair(left, right, max_disparity):
    levels = -(-max_disparity // 16) * 16
    matcher = cv2.StereoSGBM_create(
        minDisparity=0,
        numDisparities=levels,
        blockSize=5,
        P1=8 * 3 * 25,
        P2=32 * 3 * 25,
        uniquenessRatio=10,
        speckleWindowSize=200,
        speckleRange=2,
        disp12MaxDiff=1,
        mode=cv2.STEREO_SGBM_MODE_SGBM_3WAY,
    )
    maps = []
    for reference, other, mirrored in ((left, right, False), (right, left, True)):
        if mirrored:
            reference, other = reference[:, ::-1], other[:, ::-1]
        padded = [cv2.copyMakeBorder(image, 0, 0, levels, 0, cv2.BORDER_REPLICATE) for image in (reference, other)]
        raw = matcher.compute(*padded)[:, levels:].astype(np.float32) / 16
        if mirrored:
            raw = raw[:, ::-1]
        raw = np.ascontiguousarray(raw)
        maps.append(np.take_along_axis(raw, background_columns(raw, raw >= 0), 1))
    return maps


def neural_pair(left, right, max_disparity, megapixels, timing):
    import os
    import types
    import warnings

    started = time.perf_counter()
    os.environ["XFORMERS_DISABLED"] = "1"
    os.environ["HF_HUB_OFFLINE"] = "1"
    warnings.filterwarnings("ignore")
    import timm
    import torch
    from omegaconf import OmegaConf
    from safetensors.torch import load_file

    root = Path(__file__).resolve().parent
    repository = root / "third_party" / "FoundationStereo"
    weights = root / "weights" / "foundation-stereo" / NEURAL_MODEL
    if not (weights / "model.safetensors").exists() or not repository.exists():
        raise SystemExit("neural matcher is not installed, run fetch_weights.py first")
    sys.path[:0] = [str(repository), str(repository / "dinov2")]
    for unused in ("trimesh", "joblib", "pandas", "open3d", "imageio"):
        sys.modules.setdefault(unused, types.ModuleType(unused))
    from dinov2.hub import backbones

    create_model = timm.create_model
    timm.create_model = lambda name, **options: create_model(name, **{**options, "pretrained": False})
    torch.hub.load = lambda source, name, **options: getattr(backbones, name)(pretrained=False)
    from core.foundation_stereo import FoundationStereo
    from core.utils.utils import InputPadder

    height, width = left.shape[:2]
    scale = min(1.0, (megapixels * 1e6 / (width * height)) ** 0.5)
    settings = OmegaConf.load(weights / "cfg.yaml")
    settings.vit_size = settings.get("vit_size", "vitl")
    settings.max_disp = int(-(-max_disparity * scale // 32) * 32)
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model = FoundationStereo(settings)
    model.load_state_dict(load_file(weights / "model.safetensors"))
    model.to(device).eval()
    timing["load_seconds"] = time.perf_counter() - started
    timing["variant"] = f"neural:foundation-stereo-{settings.vit_size}@{device.type}"

    maps = []
    for reference, other, mirrored in ((left, right, False), (right, left, True)):
        tensors = []
        for image in (reference, other):
            if scale < 1:
                image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
            image = image[:, ::-1, ::-1] if mirrored else image[:, :, ::-1]
            tensors.append(torch.from_numpy(image.copy()).to(device).float().permute(2, 0, 1)[None])
        padder = InputPadder(tensors[0].shape, divis_by=32, force_square=False)
        with torch.no_grad():
            padded = model(*padder.pad(*tensors), iters=NEURAL_ITERATIONS, test_mode=True)
        found = padder.unpad(padded.float())[0, 0].cpu().numpy()
        found = np.ascontiguousarray(found[:, ::-1] if mirrored else found)
        maps.append(cv2.resize(found, (width, height), interpolation=cv2.INTER_LINEAR) * (width / found.shape[1]))
    return maps


def warp(image, disparity, reliable, shift):
    height, width = disparity.shape
    target = np.arange(width, dtype=np.float32)[None] + shift * disparity
    row_offset = np.arange(height)[:, None] * width
    layers = np.full((2, height * width), -1, np.float32)
    for layer, chosen in zip(layers, (reliable, ~reliable)):
        for column in (np.floor(target).astype(np.int64), np.ceil(target).astype(np.int64)):
            inside = chosen & (column >= 0) & (column < width)
            np.maximum.at(layer, (row_offset + column)[inside], disparity[inside])
    trusted, guessed = (cv2.medianBlur(layer, 3) for layer in layers.reshape(2, height, width))
    warped = np.where(trusted >= 0, trusted, guessed)
    source = np.arange(width, dtype=np.float32)[None] - shift * warped
    color = cv2.remap(image, source, row_grid(disparity.shape), cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    seen = cv2.erode((warped >= 0).astype(np.uint8), np.ones((1, 2 * EDGE_TRIM + 1), np.uint8))
    return color.astype(np.float32), warped, seen * (1 + (trusted >= 0))


def interpolate(left, right, disparity_left, disparity_right, reliable_left, reliable_right, phase):
    color_left, depth_left, rank_left = warp(left, disparity_left, reliable_left, -phase)
    color_right, depth_right, rank_right = warp(right, disparity_right, reliable_right, 1 - phase)
    nearer = np.sign(depth_left - depth_right) * (np.abs(depth_left - depth_right) > CONSISTENCY_TOLERANCE)
    order = np.where(rank_left == rank_right, nearer, np.sign(rank_left.astype(np.int8) - rank_right.astype(np.int8)))
    left_weight = np.choose(order.astype(np.int8) + 1, (0, 1 - phase, 1)).astype(np.float32)[..., None]
    frame = color_left * left_weight + color_right * (1 - left_weight)
    known = (rank_left > 0) | (rank_right > 0)
    nearest = background_columns(np.maximum(depth_left, depth_right), known)
    frame = np.take_along_axis(frame, nearest[..., None], 1)
    frame = np.where(known[..., None], frame, cv2.blur(frame, (1, HOLE_SMOOTHING)))
    return frame.round().clip(0, 255).astype(np.uint8)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("left")
    parser.add_argument("right")
    parser.add_argument("--phases", type=float, nargs="+", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--matcher", choices=("sgbm", "neural"), default="neural")
    parser.add_argument("--max-disparity", type=int)
    parser.add_argument("--match-megapixels", type=float, default=1.6)
    parser.add_argument("--disparity-left")
    parser.add_argument("--disparity-right")
    arguments = parser.parse_args()

    left = cv2.imread(arguments.left, cv2.IMREAD_COLOR)
    right = cv2.imread(arguments.right, cv2.IMREAD_COLOR)
    if left is None or right is None:
        raise SystemExit("cannot read input images")
    if left.shape != right.shape:
        raise SystemExit(f"image sizes differ: {left.shape[1::-1]} and {right.shape[1::-1]}")
    height, width = left.shape[:2]
    max_disparity = arguments.max_disparity or width // 4
    out = Path(arguments.out)
    out.mkdir(parents=True, exist_ok=True)
    timing = {"engine": "stereo", "width": width, "height": height, "load_seconds": 0.0, "warmup_seconds": 0.0}

    started = time.perf_counter()
    given = arguments.disparity_left or arguments.disparity_right
    if given:
        if not (arguments.disparity_left and arguments.disparity_right):
            raise SystemExit("--disparity-left and --disparity-right must be given together")
        timing["variant"] = "given"
        maps = []
        for path in (arguments.disparity_left, arguments.disparity_right):
            encoded = cv2.imread(path, cv2.IMREAD_UNCHANGED)
            if encoded is None or encoded.shape != (height, width):
                raise SystemExit(f"disparity map {path} is missing or does not match the image size")
            maps.append(encoded.astype(np.float32) / 64)
    elif arguments.matcher == "sgbm":
        timing["variant"] = "sgbm"
        maps = sgbm_pair(left, right, max_disparity)
    else:
        maps = neural_pair(left, right, max_disparity, arguments.match_megapixels, timing)
    (mended_left, reliable_left), (mended_right, reliable_right) = verify(maps[0], maps[1], -1), verify(maps[1], maps[0], 1)
    disparity_left, disparity_right = maps if given else (mended_left, mended_right)
    timing["disparity_seconds"] = time.perf_counter() - started - timing["load_seconds"]

    for name, disparity in (("disparity_left.png", disparity_left), ("disparity_right.png", disparity_right)):
        cv2.imwrite(str(out / name), (disparity * 64).round().clip(0, 65535).astype(np.uint16))

    timing["frames"] = []
    for phase in arguments.phases:
        started = time.perf_counter()
        frame = interpolate(left, right, disparity_left, disparity_right, reliable_left, reliable_right, phase)
        timing["frames"].append({"phase": phase, "seconds": time.perf_counter() - started})
        cv2.imwrite(str(out / f"frame_{phase:.3f}.png"), frame)
    (out / "timing.json").write_text(json.dumps(timing, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"stereo engine failed: {error}", file=sys.stderr)
        sys.exit(1)
