#!/usr/bin/env python3
"""Validate exported groups and assemble the additive device-transfer directory."""

import argparse
import hashlib
import json
import shutil
import urllib.request
from pathlib import Path

from safetensors import safe_open


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(16 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--work", required=True, type=Path)
parser.add_argument("--asset-root", type=Path)
args = parser.parse_args()
work = args.work.resolve()
root = args.asset_root.resolve() if args.asset_root else work / "coreai"
names = ["input", "join"] + [f"image_{i:02}" for i in range(5)] + [f"text_{i:02}" for i in range(5)] + [f"shared_{i:02}" for i in range(28)] + ["output", "te_embed"] + [f"te_{i:02}" for i in range(32)] + ["vae"]
assert len(names) == 75
components = []
for name in names:
    receipt = json.loads((root / (name + ".json")).read_text())
    if not receipt["completed"] or receipt["component"] != name:
        raise RuntimeError(f"Incomplete component {name}")
    asset = root / (name + ".aimodel")
    for relative, expected in receipt["asset_files_sha256"].items():
        actual = file_sha256(asset / relative)
        if actual != expected:
            raise RuntimeError(f"Corrupt exported asset {name}/{relative}")
    components.append(receipt)
with safe_open(work / "weights/vae.safetensors", framework="pt", device="cpu") as weights:
    mean = weights.get_tensor("bn.running_mean").float().tolist()
    variance = weights.get_tensor("bn.running_var").float().tolist()
caption = json.loads((work / "fixture/caption.json").read_text())
if (root / "fixture").exists():
    raise RuntimeError("Fixture transfer directory already exists")
shutil.copytree(work / "fixture", root / "fixture")
base = "https://huggingface.co/VisualInference/FLUX-3-Image-Klein-MLX-8bit/resolve/4e3428b948f1c5f4ce8c5f69c776e34e237792d5/"
for name in ["LICENSE.md", "NOTICE.md"]:
    with urllib.request.urlopen(base + name, timeout=30) as response:
        (root / name).write_bytes(response.read())
(root / "MODIFICATIONS.txt").write_text(
    "Experimental CoreAI text-to-image derivative of FLUX 3 Image Klein. "
    "DiT and Qwen3-VL heavy linear weights converted from pinned BF16 to INT4 symmetric group32. "
    "DiT floating-point math uses BF16 when recorded in its component receipts; other weights use FP16. Reference-image paths are omitted. "
    "Fixed 512px canvas and retained caption. Mandatory input and output filtering retained.\n"
)
plan = {
    "caption": caption, "components": components, "bn_mean": mean, "bn_var": variance, "bn_eps": 1e-4,
    "fixture_files_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((root / "fixture").iterdir()) if p.is_file()},
    "asset_bytes": sum(c["asset_bytes"] for c in components),
    "source_spec": json.loads((Path(__file__).parent / "model-spec.json").read_text()),
}
(root / "model-plan.json").write_text(json.dumps(plan, indent=2) + "\n")
print("Validated", len(components), "components,", round(plan["asset_bytes"] / 1e9, 3), "GB")
print("Transfer source:", root)
