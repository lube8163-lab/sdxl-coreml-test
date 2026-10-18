#!/usr/bin/env python3
"""Compare promoted BF16 CoreAI math with FP32 math using identical constants."""

import argparse
import asyncio
import gc
import json
import os
from pathlib import Path

os.environ["USE_OS_COREAI"] = "1"
import ml_dtypes
import numpy as np
from coreai.runtime import AIModel, ComputeUnitKind, NDArray, SpecializationOptions

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("component", choices=["input", "shared_00"])
parser.add_argument("--work", required=True, type=Path)
parser.add_argument("--bf16-root", required=True, type=Path)
parser.add_argument("--fp32-root", required=True, type=Path)
parser.add_argument("--diagnostics", type=Path)
args = parser.parse_args()
if args.component == "input":
    assert args.diagnostics
    metadata = json.loads((args.diagnostics / "failure-inputs.json").read_text())
    assert metadata["component"] == "input"
    inputs = {name: np.fromfile(args.diagnostics / item["file"], dtype="<f4").reshape(item["shape"]) for name, item in metadata["inputs"].items()}
    names = ["image_h", "text_h", "early_image", "early_text", "shared_mods", "image_vec"]
    required = ["image_h", "text_h"]
else:
    root = args.work / "block-smoke"
    metadata = json.loads((root / "smoke.json").read_text())
    inputs = {name: np.fromfile(root / (name + ".f32"), dtype="<f4").reshape(metadata[name + "_shape"]) for name in ["hidden", "mods"]}
    names = required = ["hidden"]


async def execute(root, dtype):
    model = await AIModel.load(root / (args.component + ".aimodel"), specialization_options=SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu()))
    function = model.load_function("main")
    result = await function(inputs={name: NDArray(values.astype(dtype)) for name, values in inputs.items()})
    output = {name: result[name].numpy().astype(np.float32) for name in names}
    del result, function, model
    gc.collect()
    return output


async def main():
    expected = await execute(args.fp32_root, np.float32)
    actual = await execute(args.bf16_root, ml_dtypes.bfloat16)
    outputs = {name: {"finite": bool(np.isfinite(values).all()), "relative_rmse": float(np.linalg.norm(values-expected[name])/max(np.linalg.norm(expected[name]), 1e-9)), "minimum": float(values.min()), "maximum": float(values.max())} for name, values in actual.items()}
    passed = all(item["finite"] for item in outputs.values()) and all(outputs[name]["relative_rmse"] < .03 for name in required)
    report = {"component": args.component, "scope": "Real weight constants retained verbatim, BF16 CoreAI math vs FP32 CoreAI math; not an image-quality metric. Input case uses actual captured phone features; shared case uses random synthetic activations.", "outputs": outputs, "passed": passed}
    destination = args.work / (args.component + "-bf16-vs-fp32-validation.json")
    destination.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)
    assert passed

asyncio.run(main())
