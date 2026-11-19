import argparse
import shlex
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np
import Quartz
from Foundation import NSURL

ROOT = Path(__file__).resolve().parent
PRECONVERGED = {"rife", "vt", "blend"}


def run_engine(engine, left, right, phases, out, extra=()):
    out.mkdir(parents=True, exist_ok=True)
    command = [ROOT / "engines" / engine / "run", left, right, "--phases", *[f"{p:g}" for p in phases], "--out", out, *extra]
    subprocess.run([str(part) for part in command], check=True)
    return [out / f"frame_{p:.3f}.png" for p in phases]


def shift(image, dx):
    matrix = np.float32([[1, 0, dx], [0, 1, 0]])
    return cv2.warpAffine(image, matrix, image.shape[1::-1], flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REPLICATE)


def read_spatial(path):
    source = Quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(str(path)), None)
    groups = (source and Quartz.CGImageSourceCopyProperties(source, None) or {}).get(Quartz.kCGImagePropertyGroups, [])
    pair = next((g for g in groups if g.get(Quartz.kCGImagePropertyGroupType) == Quartz.kCGImagePropertyGroupTypeStereoPair), None)
    if pair is None:
        sys.exit(f"{path} has no stereo pair group, it is not a spatial photo")
    options = {
        Quartz.kCGImageSourceCreateThumbnailFromImageAlways: True,
        Quartz.kCGImageSourceCreateThumbnailWithTransform: True,
        Quartz.kCGImageSourceThumbnailMaxPixelSize: 16384,
    }
    eyes = []
    for key in (Quartz.kCGImagePropertyGroupImageIndexLeft, Quartz.kCGImagePropertyGroupImageIndexRight):
        image = Quartz.CGImageSourceCreateThumbnailAtIndex(source, pair[key], options)
        width, height = Quartz.CGImageGetWidth(image), Quartz.CGImageGetHeight(image)
        srgb = Quartz.CGColorSpaceCreateWithName(Quartz.kCGColorSpaceSRGB)
        context = Quartz.CGBitmapContextCreate(None, width, height, 8, width * 4, srgb, Quartz.kCGImageAlphaNoneSkipLast)
        Quartz.CGContextDrawImage(context, Quartz.CGRectMake(0, 0, width, height), image)
        pixels = Quartz.CGDataProviderCopyData(Quartz.CGImageGetDataProvider(Quartz.CGBitmapContextCreateImage(context)))
        eyes.append(np.frombuffer(pixels, np.uint8).reshape(height, width, 4)[:, :, 2::-1].copy())
    print(f"spatial photo: {Quartz.CGImageSourceGetCount(source)} images, left #{pair[Quartz.kCGImagePropertyGroupImageIndexLeft]} {eyes[0].shape[1]}x{eyes[0].shape[0]}, right #{pair[Quartz.kCGImagePropertyGroupImageIndexRight]} {eyes[1].shape[1]}x{eyes[1].shape[0]}, baseline {pair.get(Quartz.kCGImagePropertyGroupImageBaseline)}, disparity adjustment {pair.get(Quartz.kCGImagePropertyGroupImageDisparityAdjustment)}")
    return eyes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("left", type=Path)
    parser.add_argument("right", type=Path, nargs="?")
    parser.add_argument("--engine", default="vt")
    parser.add_argument("--engine-args", default="")
    parser.add_argument("--frames", type=int, default=3)
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--converge", type=float, nargs=2, metavar=("X", "Y"))
    parser.add_argument("--fps", type=float, default=12)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    if args.right:
        left = cv2.imread(str(args.left), cv2.IMREAD_COLOR)
        right = cv2.imread(str(args.right), cv2.IMREAD_COLOR)
        if left is None or right is None:
            sys.exit("cannot read input images")
    else:
        left, right = read_spatial(args.left)
    if abs(left.shape[1] / left.shape[0] - right.shape[1] / right.shape[0]) > 0.01:
        sys.exit(f"image shapes differ: {left.shape[1::-1]} and {right.shape[1::-1]}")
    if left.shape != right.shape:
        right = cv2.resize(right, left.shape[1::-1], interpolation=cv2.INTER_LANCZOS4)
    if left.shape[1] > args.width:
        size = (args.width, round(left.shape[0] * args.width / left.shape[1]))
        left = cv2.resize(left, size, interpolation=cv2.INTER_AREA)
        right = cv2.resize(right, size, interpolation=cv2.INTER_AREA)
    height, width = left.shape[:2]
    gain = left.std(axis=(0, 1)) / right.std(axis=(0, 1))
    right = np.clip((right - right.mean(axis=(0, 1))) * gain + left.mean(axis=(0, 1)), 0, 255).astype(np.uint8)

    sift = cv2.SIFT_create(8000)
    left_points, left_features = sift.detectAndCompute(cv2.cvtColor(left, cv2.COLOR_BGR2GRAY), None)
    right_points, right_features = sift.detectAndCompute(cv2.cvtColor(right, cv2.COLOR_BGR2GRAY), None)
    candidates = cv2.BFMatcher().knnMatch(right_features, left_features, k=2)
    matches = [a for a, b in candidates if a.distance < 0.7 * b.distance]
    source = np.float64([right_points[m.queryIdx].pt for m in matches])
    target = np.float64([left_points[m.trainIdx].pt for m in matches])
    if len(matches) < 30:
        sys.exit(f"only {len(matches)} feature matches between the images")

    design = np.column_stack([source, np.ones(len(source))])
    rng = np.random.default_rng(0)
    inliers = np.zeros(len(source), bool)
    for _ in range(2000):
        sample = rng.choice(len(source), 3, replace=False)
        if abs(np.linalg.det(design[sample])) < 1e-6:
            continue
        candidate = np.abs(design @ np.linalg.solve(design[sample], target[sample, 1]) - target[:, 1]) < 1.5
        if candidate.sum() > inliers.sum():
            inliers = candidate
    a, b, c = np.linalg.lstsq(design[inliers], target[inliers, 1], rcond=None)[0]
    rotation = np.degrees(np.arctan2(a, b))
    scale = np.hypot(a, b)
    if abs(rotation) > 10 or not 0.8 < scale < 1.25:
        sys.exit(f"implausible alignment: rotation {rotation:.1f} deg, scale {scale:.3f}")

    def aligned(image, dx, border):
        matrix = np.float32([[b, -a, dx], [a, b, c]])
        return cv2.warpAffine(image, matrix, (width, height), flags=cv2.INTER_LANCZOS4, borderMode=border)

    disparity = target[inliers, 0] - (b * source[inliers, 0] - a * source[inliers, 1])
    if args.converge:
        half = width // 16
        x, y = np.clip(np.int64(np.float64(args.converge) * (width, height)), half, (width - half, height - half))
        start = max(0, x - half - int(disparity.max()) - half)
        stop = min(width, x + half - int(disparity.min()) + half)
        strip = aligned(right, 0, cv2.BORDER_REPLICATE)[y - half:y + half, start:stop]
        scores = cv2.matchTemplate(strip, left[y - half:y + half, x - half:x + half], cv2.TM_CCOEFF_NORMED)
        subject_shift = float(x - half - start - scores.argmax())
    else:
        subject_shift = np.median(disparity)
    far_shift = np.percentile(disparity, 1) - 0.01 * width
    engine_shift = subject_shift if args.engine in PRECONVERGED else far_shift

    coverage = np.full((height, width), 255, np.uint8)
    valid = aligned(coverage, subject_shift, cv2.BORDER_CONSTANT) & aligned(coverage, engine_shift, cv2.BORDER_CONSTANT)
    columns = np.flatnonzero(valid.mean(axis=0) > 230)
    rows = np.flatnonzero(valid[:, columns].mean(axis=1) > 252)
    columns = columns[valid[rows][:, columns].mean(axis=0) > 252]
    x0, y0 = columns[0], rows[0]
    x1 = x0 + (columns[-1] + 1 - x0) // 2 * 2
    y1 = y0 + (rows[-1] + 1 - y0) // 2 * 2

    args.out.mkdir(parents=True, exist_ok=True)
    sequence = [left]
    if args.frames:
        engine_dir = args.out / "engine"
        engine_dir.mkdir(exist_ok=True)
        cv2.imwrite(str(engine_dir / "left.png"), left)
        cv2.imwrite(str(engine_dir / "right.png"), aligned(right, engine_shift, cv2.BORDER_REPLICATE))
        phases = [(i + 1) / (args.frames + 1) for i in range(args.frames)]
        outputs = run_engine(args.engine, engine_dir / "left.png", engine_dir / "right.png", phases, engine_dir, shlex.split(args.engine_args))
        for phase, path in zip(phases, outputs):
            sequence.append(shift(cv2.imread(str(path), cv2.IMREAD_COLOR), phase * (subject_shift - engine_shift)))
    sequence.append(aligned(right, subject_shift, cv2.BORDER_REPLICATE))
    sequence += sequence[-2:0:-1]

    for stale in args.out.glob("loop_*.png"):
        stale.unlink()
    for index, frame in enumerate(sequence):
        cv2.imwrite(str(args.out / f"loop_{index:02d}.png"), frame[y0:y1, x0:x1])

    source_args = ["-framerate", f"{args.fps:g}", "-i", str(args.out / "loop_%02d.png")]
    palette = "scale='min(iw,800)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"
    subprocess.run(["ffmpeg", "-y", "-v", "error", *source_args, "-vf", palette, "-loop", "0", str(args.out / "wiggle.gif")], check=True)
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-stream_loop", "7", *source_args, "-pix_fmt", "yuv420p", "-crf", "18", str(args.out / "wiggle.mp4")], check=True)

    print(f"matches {inliers.sum()}/{len(matches)}  rotation {rotation:+.2f} deg  scale {scale:.4f}  vertical {c:+.1f} px")
    print(f"disparity {np.percentile(disparity, 1):+.0f}..{np.percentile(disparity, 99):+.0f} px  converged at {subject_shift:+.1f} px")
    print(f"{len(sequence)} frames {x1 - x0}x{y1 - y0}  {args.out / 'wiggle.gif'}  {args.out / 'wiggle.mp4'}")


if __name__ == "__main__":
    main()
