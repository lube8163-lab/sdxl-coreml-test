#!/usr/bin/env python3
"""Promote a previously verified CoreAI DiT graph's FP16 math to BF16.

Retains every serialized constant (including INT4 weights) unchanged, inserts
explicit FP16-constant -> BF16 casts, and retypes floating-point graph values.
Existing FP32 norm/rotary math stays FP32. Uses version-pinned CoreAI MLIR APIs;
the original assets remain untouched and the rewritten module must verify.
"""

import argparse
import hashlib
import json
import resource
import time
from pathlib import Path

from coreai.authoring import AIModelAsset
from coreai._compiler import ir
from coreai._compiler.dialects import coreai


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(16 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("component")
parser.add_argument("--work", required=True, type=Path)
parser.add_argument("--output-root", required=True, type=Path)
parser.add_argument("--target-dtype", choices=["bfloat16", "float32"], default="bfloat16")
args = parser.parse_args()
started = time.monotonic()
source_root = args.work / "coreai"
source = source_root / (args.component + ".aimodel")
receipt = json.loads((source_root / (args.component + ".json")).read_text())
assert receipt["completed"] and receipt["compute_dtype"] == "float16" and receipt["source_weight_file"] == "dit"
destination = args.output_root / source.name
receipt_path = args.output_root / (args.component + ".json")
if receipt_path.exists() and destination.is_dir():
    previous = json.loads(receipt_path.read_text())
    assert previous["compute_dtype"] == args.target_dtype and previous["int4_constants_unchanged"]
    print(args.component, "already promoted", flush=True)
    raise SystemExit(0)
assert not destination.exists()
args.output_root.mkdir(parents=True, exist_ok=True)
for relative, expected in receipt["asset_files_sha256"].items():
    assert sha256(source / relative) == expected, relative
program = AIModelAsset.load(source).program
module = program._module._mlir_module
graphs = list(module.body.operations)
assert graphs and all(g.operation.name == "coreai.graph" for g in graphs)
operations = [op for graph in graphs for op in graph.regions[0].blocks[0].operations]
assert all(not op.regions for op in operations), "Nested regions need an explicit transformation"
original_constants = [(op, tuple(result.type for result in op.results), {a.name: a.attr for a in op.attributes}) for op in operations if op.operation.name == "coreai.constant"]
int4_count = sum("si4>" in str(result.type) for op in operations if op.operation.name == "coreai.constant" for result in op.results)

with module.context, ir.Location.unknown():
    def promoted_type(value_type):
        if ir.RankedTensorType.isinstance(value_type):
            tensor = ir.RankedTensorType(value_type)
            if ir.F16Type.isinstance(tensor.element_type):
                return ir.RankedTensorType.get(tensor.shape, ir.BF16Type.get() if args.target_dtype == "bfloat16" else ir.F32Type.get())
        return value_type

    for graph in graphs:
        signature = ir.FunctionType(graph.attributes["function_type"].value)
        graph.attributes["function_type"] = ir.TypeAttr.get(ir.FunctionType.get([promoted_type(t) for t in signature.inputs], [promoted_type(t) for t in signature.results]))
        for argument in graph.regions[0].blocks[0].arguments:
            argument.set_type(promoted_type(argument.type))
    for op in operations:
        if op.operation.name == "coreai.constant":
            for result in op.results:
                converted_type = promoted_type(result.type)
                if converted_type != result.type:
                    cast = coreai.CastOp(converted_type, result, ip=ir.InsertionPoint.after(op))
                    result.replace_all_uses_except(cast.result, cast.operation)
        else:
            for result in op.results:
                result.set_type(promoted_type(result.type))
    assert module.operation.verify()
    for op, result_types, attributes in original_constants:
        assert tuple(result.type for result in op.results) == result_types
        assert {a.name: a.attr for a in op.attributes} == attributes
    if receipt["compression"] != "none":
        assert int4_count > 0
    elided = module.operation.get_asm(large_elements_limit=4, large_resource_limit=4)
    (args.output_root / (args.component + "-elided.mlir")).write_text(elided)
    program.save_asset(destination)

prior_hashes = receipt["asset_files_sha256"]
receipt.update({
    "compute_dtype": args.target_dtype, "floating_point_constant_storage": "original FP16 constants, explicitly cast to " + args.target_dtype + " for math",
    "int4_constants_unchanged": True, "int4_constant_count": int4_count,
    "source_asset_files_sha256": prior_hashes,
    "precision_transformation": "Preserve original constants, FP16 graph values -> " + args.target_dtype + "; retain pre-existing FP32 operations",
    "precision_transform_script_sha256": sha256(Path(__file__)),
    "asset_files_sha256": {str(p.relative_to(destination)): sha256(p) for p in sorted(destination.rglob("*")) if p.is_file()},
    "asset_bytes": sum(p.stat().st_size for p in destination.rglob("*") if p.is_file()),
    "input_dtypes": ["torch." + args.target_dtype if t == "torch.float16" else t for t in receipt["input_dtypes"]],
    "elapsed_seconds": time.monotonic() - started,
    "max_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
})
receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
print(args.component, args.target_dtype, "math; unchanged INT4 constants:", int4_count, "bytes:", receipt["asset_bytes"], flush=True)
