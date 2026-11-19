#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"

cd "$root/engines/rife"
[[ -d .venv ]] || uv venv --python 3.12
VIRTUAL_ENV="$PWD/.venv" uv pip install --quiet mlx numpy pillow
[[ -d third_party/rife-mlx ]] || git clone --quiet --depth 1 https://github.com/jstepien/rife-mlx third_party/rife-mlx
mkdir -p weights
[[ -s weights/model.safetensors ]] || curl -fsSL --retry 3 -o weights/model.safetensors https://huggingface.co/mlx-community/RIFE-4.25/resolve/main/model.safetensors

swift build -c release --package-path "$root/engines/vt"

if [[ "${1:-}" == "stereo" ]]; then
  cd "$root/engines/stereo"
  [[ -d .venv ]] || uv venv --python 3.12 .venv
  uv pip install --quiet --python .venv/bin/python -r requirements.txt
  [[ -s weights/foundation-stereo/11-33-40/model.safetensors ]] || .venv/bin/python fetch_weights.py
fi

cd "$root"
uv sync --quiet
