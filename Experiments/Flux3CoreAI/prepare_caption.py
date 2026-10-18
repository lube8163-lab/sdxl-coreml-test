#!/usr/bin/env python3
"""Retain a fixed benign caption, exact Qwen tokens and reference noise/schedule."""

import argparse
import hashlib
import json
import math
import urllib.request
from pathlib import Path

import numpy as np
import torch
from tokenizers import Tokenizer

from models import text_position_inputs

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--work", required=True, type=Path)
args = parser.parse_args()
work = args.work.resolve()
folder = work / "fixture"
folder.mkdir(parents=True, exist_ok=False)
tokenizer_dir = work / "tokenizer"
tokenizer_dir.mkdir(exist_ok=True)
base = "https://huggingface.co/VisualInference/FLUX-3-Image-Klein-MLX-8bit/resolve/4e3428b948f1c5f4ce8c5f69c776e34e237792d5/text_encoder/"
hashes = {}
for filename in ["tokenizer.json", "tokenizer_config.json", "chat_template.json", "config.json"]:
    destination = tokenizer_dir / filename
    if not destination.exists():
        with urllib.request.urlopen(base + filename, timeout=30) as response:
            destination.write_bytes(response.read())
    hashes[filename] = hashlib.sha256(destination.read_bytes()).hexdigest()
original = "A red apple beside a blue ceramic mug on a wooden table, soft window light."
caption = (
    "A realistic still-life photograph on a warm oak table beside a window. "
    "A single ripe red apple sits on the left, with a small blue glazed ceramic mug on the right. "
    "The mug has one clearly visible handle facing right. Soft natural window light enters from "
    "the left and produces gentle shadows across the wood grain. The background is an uncluttered, "
    "softly blurred cream-colored wall. Both objects are fully visible near the center of the frame. "
    "Use natural colors, detailed materials, and a calm photographic composition, with no people or lettering."
)
chat = "<|im_start|>user\n" + caption + "<|im_end|>\n<|im_start|>assistant\n"
tokenizer = Tokenizer.from_file(str(tokenizer_dir / "tokenizer.json"))
token_ids = tokenizer.encode(chat, add_special_tokens=False).ids
assert token_ids[0] == 151644 and tokenizer.decode(token_ids, skip_special_tokens=False) == chat
real = len(token_ids)
length = math.ceil(real / 80) * 80
if length > 240:
    raise ValueError("This fixed-caption probe is limited to at most 240 tokens")
token_ids += [151643] * (length - real)
np.asarray(token_ids, dtype="<i4").tofile(folder / "token_ids.i32")
cos, sin, mask = text_position_inputs(real, length)
for name, tensor in [("cos", cos), ("sin", sin), ("mask", mask)]:
    tensor.float().numpy().astype("<f4").tofile(folder / (name + ".f32"))
noise = torch.randn((1024, 128), generator=torch.Generator().manual_seed(42)).bfloat16().float()
noise.numpy().astype("<f4").tofile(folder / "noise.f32")
t = torch.linspace(1.0, 0.0, 17)
schedule = (6.93 * t / (1.0 + (6.93 - 1.0) * t)).tolist()
plan = {
    "format_version": 1, "model": "FLUX 3 Image Klein distilled", "width": 512, "height": 512,
    "seed": 42, "steps": 16, "alpha": 6.93, "schedule": schedule,
    "original_prompt": original, "expanded_caption": caption,
    "caption_expander": "Codex supplied this fixed full-scene caption before the offline device test",
    "exact_tokenizer_input": chat, "text_length": length, "real_tokens": real,
    "token_ids": token_ids, "tokenizer_sha256": hashes,
    "text_feature_layers": [4, 8, 12, 16, 20, 24, 28, 32],
    "text_feature_width": 20480,
    "noise_dtype_roundtrip": "PyTorch seed42 float32 -> BF16 -> float32",
    "fixture_file_hashes": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(folder.iterdir()) if p.is_file()},
}
(folder / "caption.json").write_text(json.dumps(plan, indent=2) + "\n")
print(json.dumps({"real_tokens": real, "text_length": length, "caption": caption}, indent=2))
