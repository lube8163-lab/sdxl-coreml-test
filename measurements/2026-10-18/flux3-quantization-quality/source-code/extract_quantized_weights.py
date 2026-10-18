#!/usr/bin/env python3
"""Extract actual CoreAI INT4 bytes/scales for a controlled CUDA comparison.

No quantizer is approximated or rerun. Private CoreAI compiler API is version
pinned as in README. Zero shifts/biases are checked, not silently discarded.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np
from safetensors.numpy import save_file
from coreai.authoring import AIModelAsset
from coreai._compiler import ir
from coreai._compiler._mlir_libs._coreaiIR._bindings import compiler


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        while data := f.read(16 * 1024 * 1024): h.update(data)
    return h.hexdigest()


def raw_constant(value):
    t = ir.RankedTensorType(value.type)
    kind = str(t.element_type)
    bits = {'si4': 4, 'f16': 16, 'f32': 32}[kind]
    raw = np.empty((math.prod(t.shape) * bits + 7) // 8, dtype=np.uint8)
    compiler.copy_constant_value_to_array(constant_op=value.owner, destination=raw)
    return raw, list(t.shape), kind


p = argparse.ArgumentParser(description=__doc__)
p.add_argument('component')
p.add_argument('--source-root', type=Path, required=True)
p.add_argument('--output-root', type=Path, required=True)
a = p.parse_args()
source_receipt = json.loads((a.source_root / (a.component + '.json')).read_text())
assert source_receipt['completed'] and source_receipt['compression'] == 'int4-symmetric-g32-linear-only'
asset = a.source_root / (a.component + '.aimodel')
for relative, expected in source_receipt['asset_files_sha256'].items(): assert digest(asset / relative) == expected
a.output_root.mkdir(parents=True, exist_ok=True)
destination = a.output_root / (a.component + '.safetensors')
receipt_path = a.output_root / (a.component + '.json')
if destination.exists() or receipt_path.exists():
    prior = json.loads(receipt_path.read_text())
    assert prior['source_asset_files_sha256'] == source_receipt['asset_files_sha256']
    assert digest(destination) == prior['sha256']
    print(a.component, 'already verified', flush=True)
    raise SystemExit()

program = AIModelAsset.load(asset).program
main = next(g for g in program._module._mlir_module.body.operations if g.attributes['sym_name'].value == 'main')
ops = list(main.regions[0].blocks[0].operations)
quant_ops = [op for op in ops if op.operation.name == 'coreai.blockwise_shift_scale']
if a.component.startswith('te_'):
    names = ['self_attn.q_proj.weight', 'self_attn.k_proj.weight', 'self_attn.v_proj.weight', 'self_attn.o_proj.weight', 'mlp.gate_proj.weight', 'mlp.up_proj.weight', 'mlp.down_proj.weight']
    shapes = [(4096,2560),(1024,2560),(1024,2560),(2560,4096),(9728,2560),(9728,2560),(2560,9728)]
else:
    names = ['q_proj.weight', 'k_proj.weight', 'v_proj.weight', 'mlp_in.weight', 'attn_out.weight', 'mlp_out.weight']
    shapes = [(3072,3072)]*3 + [(18432,3072),(3072,3072),(3072,9216)]
assert len(quant_ops) == len(names)
data, matrices = {}, []
for name, expected_shape, op in zip(names, shapes, quant_ops):
    q, shape, kind = raw_constant(op.operands[0])
    s, scale_shape, scale_kind = raw_constant(op.operands[1])
    z, _, zero_kind = raw_constant(op.operands[2])
    b, _, bias_kind = raw_constant(op.operands[3])
    assert tuple(shape) == expected_shape and kind == zero_kind == 'si4'
    assert scale_kind == bias_kind == 'f16' and scale_shape == [shape[0], shape[1] // 32]
    assert not np.any(z) and np.all(b.view(np.float16) == 0)
    data[name + '.q'] = q
    data[name + '.scale'] = s.view(np.float16).reshape(scale_shape).copy()
    matrices.append({'name':name,'shape':shape,'block_size':32,'source_scale_dtype':'float16','zero_shift_and_bias_verified':True})

# Retain real norm values for an independent one-block reconstruction check.
norms = []
for op in ops:
    if op.operation.name != 'coreai.constant': continue
    t = ir.RankedTensorType(op.results[0].type)
    if list(t.shape) != [128] or str(t.element_type) not in ('f16','f32'): continue
    first_use = min((i for i, user in enumerate(ops) if any(x == op.results[0] for x in user.operands)), default=len(ops))
    raw, _, dtype = raw_constant(op.results[0])
    norms.append((first_use,raw.view(np.float16 if dtype == 'f16' else np.float32).copy()))
for i, (_, value) in enumerate(sorted(norms, key=lambda item:item[0])): data[f'validation_norm_{i}'] = value

save_file(data, destination, metadata={'scope':'Actual CoreAI packed signed INT4, low nibble first, group32 along input columns; no requantization'})
receipt = {'component':a.component,'completed':True,'source_asset_files_sha256':source_receipt['asset_files_sha256'],
           'source_checkpoint_sha256':source_receipt['source_sha256'],'matrices':matrices,
           'packed_nibble_order':'low then high; signed two complement','validation_norm_count':len(norms),
           'sha256':digest(destination),'bytes':destination.stat().st_size,'extractor_sha256':digest(Path(__file__))}
receipt_path.write_text(json.dumps(receipt,indent=2)+'\n')
print(a.component, len(matrices), 'real INT4 matrices;', destination.stat().st_size, 'bytes', flush=True)
