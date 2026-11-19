import json
import sys
from pathlib import Path

import cv2
import numpy as np

areas = {
    "cauldron": (0.10, 0.51, 0.39, 0.08, 0.88),
    "echo": (0.145, 0.51, 0.345, 0.12, 0.86),
    "diana": (0.145, 0.50, 0.335, 0.10, 0.88),
    "bennu": (0.15, 0.525, 0.325, 0.08, 0.88),
    "edinburgh": (0.075, 0.515, 0.42, 0.04, 0.80),
    "bridge": (0.075, 0.515, 0.365, 0.01, 0.99),
}
root = Path(sys.argv[1])
tiles = []
for name, (left_x, right_x, span, y0, y1) in areas.items():
    card = cv2.imread(str(root / name / "card.jpg"), cv2.IMREAD_COLOR)
    height, width = card.shape[:2]
    top, bottom, size = int(y0 * height), int(y1 * height), int(span * width)
    left = card[top:bottom, int(left_x * width):int(left_x * width) + size]
    right = card[top:bottom, int(right_x * width):int(right_x * width) + size]
    cv2.imwrite(str(root / name / "left.png"), left)
    cv2.imwrite(str(root / name / "right.png"), right)
    preview = np.hstack([left, np.full((left.shape[0], 12, 3), 255, np.uint8), right])
    tiles.append(cv2.resize(preview, (1000, int(1000 * preview.shape[0] / preview.shape[1]))))
    print(name, left.shape[1], "x", left.shape[0])
cv2.imwrite(str(root / "split_sheet.jpg"), np.vstack([np.vstack([t, np.full((10, 1000, 3), 255, np.uint8)]) for t in tiles]))
