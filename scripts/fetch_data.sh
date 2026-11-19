#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}/data/middlebury"
base="https://vision.middlebury.edu/stereo/data"
scenes=("scenes2006/FullSize/Aloe" "scenes2006/FullSize/Baby1" "scenes2005/FullSize/Art")

for scene in "${scenes[@]}"; do
  name="${scene:t}"
  mkdir -p "$root/$name"
  for view in 0 1 2 3 4 5 6; do
    target="$root/$name/view$view.png"
    [[ -s "$target" ]] && continue
    curl -fsS --retry 3 -o "$target" "$base/$scene/Illum1/Exp1/view$view.png"
  done
  for disp in 1 5; do
    target="$root/$name/disp$disp.png"
    [[ -s "$target" ]] && continue
    curl -fsS --retry 3 -o "$target" "$base/$scene/disp$disp.png"
  done
done
