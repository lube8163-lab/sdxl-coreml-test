#!/usr/bin/env python3
"""Export one real-weight component; use separate processes to bound Mac RAM."""

import argparse
import gc
import hashlib
import json
import os
import re
import resource
import time
from pathlib import Path

os.environ["USE_OS_COREAI"] = "1"

import torch
import coreai_torch
from coreai_opt.base_model_compressor import ExportBackend
from coreai_opt.quantization import Quantizer, QuantizerConfig
from safetensors import safe_open

from models import (
    reference, positions, InputStage, DiffusionBlock, OutputStage, JoinStage, Decoder,
    TextLayer, TextEmbedding, text_position_inputs,
)


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(16 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", help="input, output, image_00..04, text_00..04, shared_00..27, te_embed, te_00..31, vae")
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--text-length", type=int, default=160)
    parser.add_argument("--compute-dtype", choices=["float16", "bfloat16"], default="float16")
    parser.add_argument("--output-root", type=Path)
    args = parser.parse_args()
    torch.set_num_threads(2)
    started = time.monotonic()
    work = args.work.resolve()
    out = args.output_root.resolve() if args.output_root else work / "coreai"
    out.mkdir(exist_ok=True)
    name = args.component
    if not re.fullmatch(r"(?:input|join|output|vae|te_embed|(?:image|text|shared|te)_\d{2})", name):
        parser.error("Invalid component")
    receipt_path = out / (name + ".json")
    asset = out / (name + ".aimodel")
    if receipt_path.exists() and asset.is_dir():
        prior = json.loads(receipt_path.read_text())
        if prior.get("completed") and prior.get("text_length") == args.text_length and prior.get("compute_dtype") == args.compute_dtype:
            print(name, "already exported", flush=True)
            return
        raise RuntimeError("Existing component is incomplete or uses a different text length")
    ref, ae = reference(work / "reference")
    compute_dtype = getattr(torch, args.compute_dtype)
    side = 32
    n = side * side
    m = args.text_length
    image_ids, text_ids = positions(side, m)
    compression = "none"
    weight_file = "dit"

    with torch.device("meta"):
        if name == "input":
            module = InputStage(ref)
            mapper = lambda key: key
            inputs = (torch.empty(n, 128), torch.empty(m, 20480), torch.empty(1), torch.empty(1))
            input_names = ("image", "text", "current_t", "target_t")
            output_names = ("image_h", "text_h", "early_image", "early_text", "shared_mods", "image_vec")
        elif name == "output":
            module = OutputStage(ref, n)
            mapper = lambda key: "final_layer.image." + key.removeprefix("final.")
            inputs = (torch.empty(n + m, 3072), torch.empty(1, 3072))
            input_names = ("image_hidden", "image_vec")
            output_names = ("velocity",)
        elif name == "join":
            module = JoinStage()
            mapper = lambda key: key
            inputs = (torch.empty(n, 3072), torch.empty(m, 3072))
            input_names = ("image_hidden", "text_hidden")
            output_names = ("hidden",)
        elif name == "vae":
            module = Decoder(ae)
            mapper = lambda key: key
            inputs = (torch.empty(1, 32, 64, 64),)
            input_names = ("spatial_latents",)
            output_names = ("pixels",)
            weight_file = "vae"
        elif name == "te_embed":
            module = TextEmbedding()
            mapper = lambda key: "model.language_model." + key
            inputs = (torch.empty(1, m, dtype=torch.int32),)
            input_names = ("token_ids",)
            output_names = ("hidden",)
            weight_file = "text"
        elif name.startswith("te_"):
            index = int(name.split("_")[1])
            if index >= 32:
                raise ValueError("Only the first 32 text layers are used")
            module = TextLayer()
            mapper = lambda key: f"model.language_model.layers.{index}." + key
            inputs = (torch.empty(1, m, 2560), torch.empty(1, m, 128), torch.empty(1, m, 128), torch.empty(1, 1, m, m))
            input_names = ("hidden", "cos", "sin", "mask")
            output_names = ("hidden",)
            weight_file = "text"
            compression = "int4-symmetric-g32-linear-only"
        else:
            mode, raw_index = name.split("_")
            index = int(raw_index)
            if (mode == "shared" and index >= 28) or (mode != "shared" and index >= 5):
                raise ValueError("Block index outside reference architecture")
            block = ref.Block(3072, 24, 3.0)
            module = None
            prefix = f"single_blocks.{index}." if mode == "shared" else (f"txt_mode_blocks.{index}." if mode == "text" else f"content_mode_blocks.image.{index}.")
            mapper = lambda key: prefix + key.removeprefix("block.")
            length = n + m if mode == "shared" else (m if mode == "text" else n)
            inputs = (torch.empty(length, 3072), torch.empty((2, 3, 3072) if mode == "shared" else (3, 3072)))
            input_names = ("hidden", "mods")
            output_names = ("hidden",)
            compression = "int4-symmetric-g32-linear-only"
    if module is None:
        ids = torch.cat((image_ids, text_ids)) if mode == "shared" else (text_ids if mode == "text" else image_ids)
        module = DiffusionBlock(block, ref.rope_embed(ids[None]), n if mode == "shared" else 0)

    # Replace meta parameters directly with only this component's mapped BF16 weights.
    checkpoint = work / "weights" / (weight_file + ".safetensors")
    source_receipt = json.loads((work / "weights" / (weight_file + "-source.json")).read_text())
    if not source_receipt.get("verified"):
        raise RuntimeError("Checkpoint must have a verified whole-file SHA-256")
    count = sum(p.numel() for p in module.parameters())
    state = {}
    with safe_open(checkpoint, framework="pt", device="cpu") as reader:
        for key, parameter in module.named_parameters():
            value = reader.get_tensor(mapper(key)).to(dtype=compute_dtype)
            if tuple(value.shape) != tuple(parameter.shape) or not torch.isfinite(value).all():
                raise ValueError(f"Invalid parameter {key}")
            state[key] = value
    module.load_state_dict(state, strict=True, assign=True)
    del state
    module.eval()
    inputs = tuple(torch.zeros(tuple(value.shape), dtype=value.dtype if value.dtype == torch.int32 else compute_dtype, device="cpu") for value in inputs)
    if name.startswith("te_") and name != "te_embed":
        cos, sin, mask = text_position_inputs(m, m)
        inputs = (inputs[0], cos.to(compute_dtype), sin.to(compute_dtype), mask.to(compute_dtype))

    if compression != "none":
        settings = {"op_state_spec": {"weight": {"dtype": "int4", "qscheme": "symmetric_with_clipping", "granularity": {"type": "per_block", "block_size": 32}}}, "op_input_spec": None, "op_output_spec": None}
        config = QuantizerConfig.from_dict({"quantization_config": {"execution_mode": "eager", "global_config": None, "module_type_configs": {"torch.nn.modules.linear.Linear": settings}}})
        if isinstance(module, DiffusionBlock):
            original_freqs, original_image_length = module.freqs, module.image_length
            trace_length = 16
            module.freqs = module.freqs[:, :, :trace_length]
            if module.image_length:
                module.image_length = 8
            trace_inputs = (inputs[0][:trace_length], inputs[1])
        else:
            trace_length = 8
            trace_inputs = (inputs[0][:, :trace_length], inputs[1][:, :trace_length], inputs[2][:, :trace_length], inputs[3][:, :, :trace_length, :trace_length])
        print(name, "quantizing", count, "parameters", flush=True)
        quantizer = Quantizer(module, config)
        prepared = quantizer.prepare(example_inputs=trace_inputs, dynamic_shapes=None)
        module = quantizer.finalize(prepared, backend=ExportBackend.CoreAI).eval()
        if isinstance(module, DiffusionBlock):
            module.freqs, module.image_length = original_freqs, original_image_length

    def decompose_empty_permuted(size, physical_layout, **kwargs):
        inverse = [0] * len(physical_layout)
        for i, axis in enumerate(physical_layout):
            inverse[axis] = i
        return torch.empty([size[axis] for axis in physical_layout], **kwargs).permute(inverse)

    print(name, "tracing and converting", flush=True)
    with torch.no_grad():
        exported = torch.export.export(module, args=inputs)
    table = coreai_torch.get_decomp_table()
    table[torch.ops.aten.empty_permuted.default] = decompose_empty_permuted
    decomposed = exported.run_decompositions(table)
    converter = coreai_torch.TorchConverter(mode=coreai_torch.TorchConverter.Mode.RELEASE)
    converter.add_exported_program(decomposed, input_names=input_names, output_names=output_names)
    program = converter.to_coreai()
    ir = program._module._mlir_module.operation.get_asm(large_elements_limit=4, large_resource_limit=4)
    (out / (name + "-elided.mlir")).write_text(ir)
    if compression != "none" and not re.search(r"(?:[su]?i4|int4)", ir):
        raise RuntimeError("No four-bit weights found in the exported CoreAI IR")
    program.save_asset(asset)
    hashes = {str(p.relative_to(asset)): file_sha256(p) for p in sorted(asset.rglob("*")) if p.is_file()}
    receipt = {
        "completed": True, "component": name, "text_length": m, "parameter_count": count,
        "source_weight_file": weight_file, "source_sha256": source_receipt["sha256"],
        "compression": compression, "compute_dtype": args.compute_dtype, "reference_revision": ref.__dict__.get("REFERENCE_REVISION", "dd2ae0a545abd569a87111a3a02b83e2424b1ecb"),
        "input_names": input_names, "input_shapes": [list(value.shape) for value in inputs],
        "input_dtypes": [str(value.dtype) for value in inputs], "output_names": output_names,
        "asset_files_sha256": hashes, "asset_bytes": sum(p.stat().st_size for p in asset.rglob("*") if p.is_file()),
        "elapsed_seconds": time.monotonic() - started,
        "max_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
    }
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(name, "saved", receipt["asset_bytes"], "bytes in", round(receipt["elapsed_seconds"], 1), "s", flush=True)


if __name__ == "__main__":
    main()
