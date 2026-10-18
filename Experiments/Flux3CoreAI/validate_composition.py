#!/usr/bin/env python3
"""Compare a merged CoreAI block group with the original sequential calls."""

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
parser.add_argument("component")
parser.add_argument("--source-root", required=True, type=Path)
parser.add_argument("--group-root", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
group = json.loads((args.group_root / (args.component + ".json")).read_text())
member = json.loads((args.source_root / (group["members"][0] + ".json")).read_text())
rng = np.random.default_rng(42)
hidden = (rng.standard_normal(member["input_shapes"][0]) * .3).astype(ml_dtypes.bfloat16)
mods = (rng.standard_normal(member["input_shapes"][1]) * .1).astype(ml_dtypes.bfloat16)
if mods.ndim == 3: mods[:, 2] = .5
else: mods[2] = .5


async def execute(root, name, values):
    model = await AIModel.load(root / (name + ".aimodel"), specialization_options=SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu()))
    function = model.load_function("main")
    result = await function(inputs={"hidden": NDArray(values), "mods": NDArray(mods)})
    output = result["hidden"].numpy().copy()
    del result, function, model
    gc.collect()
    return output


async def main():
    expected = hidden
    for name in group["members"]: expected = await execute(args.source_root, name, expected)
    actual = await execute(args.group_root, args.component, hidden)
    a, b = actual.astype(np.float32), expected.astype(np.float32)
    relative = float(np.linalg.norm(a-b)/max(np.linalg.norm(b), 1e-9))
    report = {"component": args.component, "members": group["members"], "scope": "Real checkpoint constants; random BF16 activations; grouped vs sequential CoreAI calls on Mac; not image-quality evaluation", "relative_rmse": relative, "max_absolute_error": float(np.max(np.abs(a-b))), "finite": bool(np.isfinite(a).all()), "exact_equal": bool(np.array_equal(a,b)), "passed": bool(np.isfinite(a).all() and relative < .01)}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)
    assert report["passed"]

asyncio.run(main())
