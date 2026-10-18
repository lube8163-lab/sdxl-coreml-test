#!/usr/bin/env python3
"""Compare a full-width real-weight INT4 CoreAI block with PyTorch on a Mac."""

import argparse
import asyncio
import json
import hashlib
import os
import shutil
from pathlib import Path

os.environ["USE_OS_COREAI"] = "1"

import numpy as np
import torch
from coreai.runtime import AIModel, ComputeUnitKind, NDArray, SpecializationOptions
from coreai_opt.quantization import Quantizer, QuantizerConfig
from coreai_opt.base_model_compressor import ExportBackend
from safetensors import safe_open

from models import reference, positions, DiffusionBlock


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--component", choices=["image_00", "shared_00"], default="shared_00")
    args = parser.parse_args()
    work = args.work.resolve()
    torch.set_num_threads(2); torch.manual_seed(42)
    ref, _ = reference(work / "reference")
    n = 1024
    m = json.loads((work / "fixture/caption.json").read_text())["text_length"]
    image_ids, text_ids = positions(32, m)
    shared = args.component == "shared_00"
    ids = torch.cat((image_ids, text_ids)) if shared else image_ids
    with torch.device("meta"):
        block = ref.Block(3072, 24, 3.0)
    wrapper = DiffusionBlock(block, ref.rope_embed(ids[None]), n if shared else 0).eval()
    prefix = "single_blocks.0." if shared else "content_mode_blocks.image.0."
    with safe_open(work / "weights/dit.safetensors", framework="pt", device="cpu") as source:
        state = {key: source.get_tensor(prefix + key.removeprefix("block.")).half() for key, _ in wrapper.named_parameters()}
    wrapper.load_state_dict(state, strict=True, assign=True)
    del state
    hidden = torch.randn(len(ids), 3072, dtype=torch.float16) * 0.3
    mods = torch.randn((2, 3, 3072) if shared else (3, 3072), dtype=torch.float16) * 0.1
    if shared: mods[:, 2] = 0.5
    else: mods[2] = 0.5
    with torch.inference_mode():
        original = wrapper(hidden, mods).float().numpy()
    config = QuantizerConfig.from_dict({"quantization_config": {"execution_mode": "eager", "global_config": None,
        "module_type_configs": {"torch.nn.modules.linear.Linear": {
            "op_state_spec": {"weight": {"dtype": "int4", "qscheme": "symmetric_with_clipping", "granularity": {"type": "per_block", "block_size": 32}}},
            "op_input_spec": None, "op_output_spec": None}}}})
    rotations, image_length = wrapper.freqs, wrapper.image_length
    wrapper.freqs = wrapper.freqs[:, :, :16]
    if shared: wrapper.image_length = 8
    quantizer = Quantizer(wrapper, config)
    prepared = quantizer.prepare(example_inputs=(hidden[:16], mods), dynamic_shapes=None)
    wrapper = quantizer.finalize(prepared, backend=ExportBackend.CoreAI).eval()
    wrapper.freqs, wrapper.image_length = rotations, image_length
    with torch.inference_mode():
        expected = wrapper(hidden, mods).float().numpy()
    options = SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu())
    model = await AIModel.load(work / "coreai" / (args.component + ".aimodel"), specialization_options=options)
    function = model.load_function("main")
    result = await function(inputs={"hidden": NDArray(hidden.numpy()), "mods": NDArray(mods.numpy())})
    actual = result["hidden"].numpy().astype(np.float32)
    relative = float(np.linalg.norm(actual - expected) / max(np.linalg.norm(expected), 1e-9))
    passed = bool(np.isfinite(actual).all() and relative < 0.01)
    receipt = {
        "component": args.component, "scope": "One full-width real-weight block, random synthetic activations, Mac OS CoreAI GPU preferred; not an image-quality evaluation",
        "source_sha256": json.loads((work / "weights/dit-source.json").read_text())["sha256"],
        "input_shape": list(hidden.shape), "output_shape": list(actual.shape), "compression": "INT4 symmetric group32 linear-only",
        "coreai_vs_quantized_pytorch_max_absolute_error": float(np.max(np.abs(actual - expected))),
        "coreai_vs_quantized_pytorch_relative_rmse": relative,
        "unquantized_vs_quantized_pytorch_relative_rmse": float(np.linalg.norm(original - expected) / max(np.linalg.norm(original), 1e-9)),
        "finite": bool(np.isfinite(actual).all()), "passed": passed,
    }
    if shared:
        smoke = work / "block-smoke"
        smoke.mkdir(exist_ok=True)
        hidden.float().numpy().astype("<f4").tofile(smoke / "hidden.f32")
        mods.float().numpy().astype("<f4").tofile(smoke / "mods.f32")
        expected.astype("<f4").tofile(smoke / "expected.f32")
        asset = work / "coreai" / (args.component + ".aimodel")
        if not (smoke / asset.name).exists():
            shutil.copytree(asset, smoke / asset.name)
        metadata = json.loads((work / "coreai" / (args.component + ".json")).read_text())
        metadata["hidden_shape"] = list(hidden.shape)
        metadata["mods_shape"] = list(mods.shape)
        metadata["fixture_hashes"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in smoke.glob("*.f32")}
        (smoke / "smoke.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (work / (args.component + "-numerical-validation.json")).write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2), flush=True)
    return passed


if __name__ == "__main__":
    raise SystemExit(0 if asyncio.run(main()) else 1)
