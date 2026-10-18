#!/usr/bin/env python3
"""Compare the text-layer port to unmodified HF inference math on shared weights.

The extraction removes optional kernel/deprecation decorators and substitutes the
checkpointing base with nn.Module for inference. Mathematical bodies are unchanged.
This is a random-weight layer test, not a complete Qwen checkpoint comparison.
"""

import argparse
import ast
import hashlib
import json
import types
import urllib.request
from pathlib import Path

import torch
from torch import nn
import torch.nn.functional as F

from models import TextLayer, text_position_inputs

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--work", required=True, type=Path)
args = parser.parse_args()
torch.set_num_threads(2); torch.manual_seed(42)
source = args.work / "reference/modeling_qwen3_vl-v4.57.1.py"
if not source.exists():
    url = "https://raw.githubusercontent.com/huggingface/transformers/v4.57.1/src/transformers/models/qwen3_vl/modeling_qwen3_vl.py"
    with urllib.request.urlopen(url, timeout=30) as response:
        source.write_bytes(response.read())
names = {"rotate_half", "repeat_kv", "eager_attention_forward", "apply_rotary_pos_emb", "Qwen3VLTextRMSNorm", "Qwen3VLTextAttention", "Qwen3VLTextMLP", "Qwen3VLTextDecoderLayer"}
tree = ast.parse(source.read_text())
selected = [node for node in tree.body if isinstance(node, (ast.ClassDef, ast.FunctionDef)) and node.name in names]
assert len(selected) == len(names)
for node in selected:
    node.decorator_list = []
    if isinstance(node, ast.ClassDef):
        for child in node.body:
            if isinstance(child, ast.FunctionDef): child.decorator_list = []
module = ast.Module(body=[ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0)] + selected, type_ignores=[])
ast.fix_missing_locations(module)
scope = {"torch": torch, "nn": nn, "GradientCheckpointingLayer": nn.Module, "ACT2FN": {"silu": F.silu}, "ALL_ATTENTION_FUNCTIONS": {}}
exec(compile(module, str(source), "exec"), scope)
config = types.SimpleNamespace(hidden_size=2560, intermediate_size=9728, num_attention_heads=32, num_key_value_heads=8, head_dim=128, attention_bias=False, attention_dropout=0.0, rms_norm_eps=1e-6, hidden_act="silu", _attn_implementation="eager")
ours = TextLayer().eval()
with torch.device("meta"):
    upstream = scope["Qwen3VLTextDecoderLayer"](config, 0).eval()
upstream.load_state_dict(ours.state_dict(), strict=True, assign=True)
hidden = torch.randn(1, 160, 2560) * 0.3
cos, sin, mask = (x.float() for x in text_position_inputs(117, 160))
with torch.inference_mode():
    expected = upstream(hidden, position_embeddings=(cos, sin), attention_mask=mask)
    actual = ours(hidden, cos, sin, mask)
maximum = float((actual - expected).abs().max())
relative = float(torch.linalg.vector_norm(actual - expected) / torch.linalg.vector_norm(expected))
passed = bool(torch.isfinite(actual).all() and torch.allclose(actual, expected, atol=1e-5, rtol=1e-5))
receipt = {"scope": "Random-weight FP32 Qwen3-VL layer inference-math comparison; 117 valid / 160 padded tokens", "reference_tag": "transformers v4.57.1", "reference_source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "max_absolute_error": maximum, "relative_rmse": relative, "passed": passed}
(args.work / "text-layer-math-validation.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt, indent=2))
raise SystemExit(0 if passed else 1)
