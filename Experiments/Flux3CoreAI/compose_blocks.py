#!/usr/bin/env python3
"""Inline consecutive verified DiT blocks into one CoreAI entry point."""

import argparse
import hashlib
import json
import resource
import time
from pathlib import Path

from coreai.authoring import AIModelAsset, AIProgram, Context, Module
from coreai.authoring.asset import _clone_graph_inline
from coreai.authoring.graph_builder import GraphOp
from coreai._compiler import ir
from coreai._compiler.dialects import coreai


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(16 * 1024 * 1024): value.update(chunk)
    return value.hexdigest()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("component")
parser.add_argument("--mode", choices=["image", "text", "shared"], required=True)
parser.add_argument("--members", nargs="+", required=True)
parser.add_argument("--source-root", required=True, type=Path)
parser.add_argument("--output-root", required=True, type=Path)
args = parser.parse_args()
assert 1 <= len(args.members) <= 8 and len(set(args.members)) == len(args.members)
assert all(name.startswith(args.mode + "_") for name in args.members)
started = time.monotonic()
args.output_root.mkdir(parents=True, exist_ok=True)
destination = args.output_root / (args.component + ".aimodel")
assert not destination.exists()
receipts = [json.loads((args.source_root / (name + ".json")).read_text()) for name in args.members]
assert all(r["completed"] and r["compute_dtype"] == "bfloat16" for r in receipts)
for name, receipt in zip(args.members, receipts):
    for relative, expected in receipt["asset_files_sha256"].items():
        assert digest(args.source_root / (name + ".aimodel") / relative) == expected

with Context():
    module = Module.create()
    programs = [AIModelAsset.load(args.source_root / (name + ".aimodel")).program for name in args.members]
    helper_bodies = {}
    mains = []
    with module:
        for program in programs:
            for graph in program._module._mlir_module.body.operations:
                name = graph.attributes["sym_name"].value
                if name == "main":
                    mains.append(graph)
                else:
                    body = graph.operation.get_asm(large_elements_limit=4, large_resource_limit=4)
                    if name in helper_bodies:
                        assert helper_bodies[name] == body, "Helper symbol collision"
                    else:
                        helper_bodies[name] = body
                        graph.operation.clone(ip=ir.InsertionPoint.current)
        assert len(mains) == len(args.members)
        signature = ir.FunctionType(mains[0].attributes["function_type"].value)
        assert all(g.attributes["function_type"] == mains[0].attributes["function_type"] for g in mains)
        wrapper = GraphOp("main", list(signature.inputs), list(signature.results), input_names=["hidden", "mods"], result_names=["hidden"])
        with wrapper.block:
            hidden, mods = wrapper.arguments
            for main in mains:
                hidden, = _clone_graph_inline([hidden, mods], main)
            coreai.OutputOp([hidden])
    module.verify()
    program = AIProgram(module)
    text = module._mlir_module.operation.get_asm(large_elements_limit=4, large_resource_limit=4)
    assert "si4>" in text
    (args.output_root / (args.component + "-elided.mlir")).write_text(text)
    program.save_asset(destination)

receipt = {"completed": True, "component": args.component, "mode": args.mode, "members": args.members,
    "compute_dtype": "bfloat16", "compression": "int4-symmetric-g32-linear-only", "parameter_count": sum(r["parameter_count"] for r in receipts),
    "source_components": [{"component": name, "asset_files_sha256": r["asset_files_sha256"]} for name, r in zip(args.members, receipts)],
    "input_names": ["hidden", "mods"], "output_names": ["hidden"],
    "asset_files_sha256": {str(p.relative_to(destination)): digest(p) for p in sorted(destination.rglob("*")) if p.is_file()},
    "asset_bytes": sum(p.stat().st_size for p in destination.rglob("*") if p.is_file()),
    "source_script_sha256": digest(Path(__file__)), "elapsed_seconds": time.monotonic()-started,
    "max_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
(args.output_root / (args.component + ".json")).write_text(json.dumps(receipt, indent=2) + "\n")
print(args.component, "members", args.members, "bytes", receipt["asset_bytes"], "RSS", receipt["max_rss_bytes"], flush=True)
