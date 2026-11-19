import collections
import subprocess
import typing
from pathlib import Path

import gdown
import numpy as np
import omegaconf
import torch
from safetensors.torch import save_file

REPOSITORY = "https://github.com/NVlabs/FoundationStereo.git"
COMMIT = "6e8806816b533e4d13ddbb95ffa907b797060a62"
FILES = {"cfg.yaml": "1kVuORLuJI0aqz6u5ZrbyE960IBLTw3P9", "model_best_bp2.pth": "1Ei-EBaF3EQA977zdjbXdmoXE7WuyJ1ib"}
CHECKPOINT_TYPES = [
    (np._core.multiarray.scalar, "numpy.core.multiarray.scalar"),
    np.dtype,
    np.dtypes.Float64DType,
    np.dtypes.Int64DType,
    dict,
    int,
    list,
    collections.defaultdict,
    typing.Any,
    omegaconf.base.ContainerMetadata,
    omegaconf.base.Metadata,
    omegaconf.DictConfig,
    omegaconf.ListConfig,
    omegaconf.nodes.AnyNode,
]

root = Path(__file__).resolve().parent
code = root / "third_party" / "FoundationStereo"
if not code.exists():
    subprocess.run(["git", "init", "--quiet", str(code)], check=True)
    subprocess.run(["git", "-C", str(code), "fetch", "--depth", "1", REPOSITORY, COMMIT], check=True)
    subprocess.run(["git", "-C", str(code), "checkout", "--quiet", "FETCH_HEAD"], check=True)

target = root / "weights" / "foundation-stereo" / "11-33-40"
target.mkdir(parents=True, exist_ok=True)
if not (target / "model.safetensors").exists():
    for name, identifier in FILES.items():
        gdown.download(id=identifier, output=str(target / name), resume=True)
    with torch.serialization.safe_globals(CHECKPOINT_TYPES):
        checkpoint = torch.load(target / "model_best_bp2.pth", map_location="cpu", weights_only=True)
    save_file({name: tensor.clone() for name, tensor in checkpoint["model"].items()}, target / "model.safetensors")
    (target / "model_best_bp2.pth").unlink()
