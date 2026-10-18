#!/usr/bin/env python3
"""Fold FP16-constant -> BF16 casts offline without changing packed INT4 data."""

import argparse
import hashlib
import json
import math
import resource
import time
from pathlib import Path

import ml_dtypes
import numpy as np
from coreai.authoring import AIModelAsset
from coreai._compiler import ir
from coreai._compiler.dialects import coreai
from coreai._compiler._mlir_libs._coreaiIR._bindings import compiler


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(16 * 1024 * 1024): value.update(chunk)
    return value.hexdigest()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("component")
parser.add_argument("--source-root", required=True, type=Path)
parser.add_argument("--output-root", required=True, type=Path)
args = parser.parse_args()
started = time.monotonic()
receipt = json.loads((args.source_root / (args.component + ".json")).read_text())
assert receipt["compute_dtype"] == "bfloat16" and receipt["completed"]
source = args.source_root / (args.component + ".aimodel")
destination = args.output_root / source.name
assert not destination.exists()
args.output_root.mkdir(exist_ok=True, parents=True)
for name, expected in receipt["asset_files_sha256"].items(): assert digest(source / name) == expected
program = AIModelAsset.load(source).program
module = program._module._mlir_module
operations = [op for graph in module.body.operations for op in graph.regions[0].blocks[0].operations]
packed = [(op, op.attributes["value"], tuple(r.type for r in op.results)) for op in operations if op.operation.name == "coreai.constant" and any("si4>" in str(r.type) for r in op.results)]
folded = 0
with module.context, ir.Location.unknown():
    for op in [item for item in operations if item.operation.name == "coreai.cast"]:
        output_type = ir.RankedTensorType(op.result.type)
        input_type = ir.RankedTensorType(op.operands[0].type)
        owner = op.operands[0].owner
        if not ir.BF16Type.isinstance(output_type.element_type) or not ir.F16Type.isinstance(input_type.element_type) or owner.name != "coreai.constant": continue
        raw = np.empty(math.prod(input_type.shape) * 2, dtype=np.uint8)
        compiler.copy_constant_value_to_array(constant_op=owner, destination=raw)
        values = raw.view(np.float16).reshape(input_type.shape).astype(ml_dtypes.bfloat16).view(np.uint16)
        attribute = ir.DenseResourceElementsAttr.get_from_buffer(values, "baked_bf16_" + str(folded), output_type, alignment=2)
        constant = coreai.ConstantOp(attribute, ip=ir.InsertionPoint(op))
        op.result.replace_all_uses_with(constant.result)
        op.operation.erase()
        if not list(owner.results[0].uses): owner.erase()
        folded += 1
    assert module.operation.verify()
    for op, value, types in packed:
        assert op.attributes["value"] == value and tuple(r.type for r in op.results) == types
    with program._module: pass
    assert module.operation.verify()
    text = module.operation.get_asm(large_elements_limit=4, large_resource_limit=4)
    (args.output_root / (args.component + "-elided.mlir")).write_text(text)
    program.save_asset(destination)
receipt.update({"source_bf16_asset_files_sha256": receipt["asset_files_sha256"], "offline_baked_bf16_constants": folded,
    "offline_constant_fold_script_sha256": digest(Path(__file__)),
    "floating_point_constant_storage": "BF16 constants baked with IEEE round-to-nearest-even; pre-existing other constants retained",
    "asset_files_sha256": {str(p.relative_to(destination)): digest(p) for p in sorted(destination.rglob("*")) if p.is_file()},
    "asset_bytes": sum(p.stat().st_size for p in destination.rglob("*") if p.is_file()),
    "elapsed_seconds": time.monotonic()-started, "max_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})
(args.output_root / (args.component + ".json")).write_text(json.dumps(receipt, indent=2) + "\n")
print(args.component, "folded", folded, "BF16 constants; INT4 constants unchanged; bytes", receipt["asset_bytes"], flush=True)
