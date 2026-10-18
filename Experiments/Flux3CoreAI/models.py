"""Text-to-image CoreAI component boundaries for the pinned FLUX.3 reference.

The BFL reference code is Apache-2.0; its license is retained in the source cache.
Qwen text math follows transformers v4.57.1's Apache-2.0 Qwen3-VL implementation.
Only text conditioning is implemented here; visual/reference-image paths are absent.
"""

import ast
import hashlib
import importlib.util
import json
import sys
import urllib.request
from pathlib import Path

import torch
from torch import nn
import torch.nn.functional as F


REFERENCE_REVISION = "dd2ae0a545abd569a87111a3a02b83e2424b1ecb"


def reference(cache: Path):
    cache.mkdir(parents=True, exist_ok=True)
    hashes = {}
    modules = []
    for filename in ["dit.py", "autoencoder.py", "LICENSE"]:
        destination = cache / filename
        path = filename if filename == "LICENSE" else "src/flux3/" + filename
        if not destination.exists():
            url = f"https://raw.githubusercontent.com/black-forest-labs/flux-3-image-klein/{REFERENCE_REVISION}/{path}"
            with urllib.request.urlopen(url, timeout=30) as response:
                destination.write_bytes(response.read())
        body = destination.read_bytes()
        hashes[path] = hashlib.sha256(body).hexdigest()
        if filename == "LICENSE":
            continue
        module_name = "flux3_coreai_reference_" + destination.stem
        spec = importlib.util.spec_from_file_location(module_name, destination)
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        if filename == "dit.py":
            if hashes[path] != "d4c0d2aea5282ae63ac32a1f3029a738ddab951bb1033d6f3a2e9bd192c89934":
                raise ValueError("Unexpected DiT source hash")

            class StripDisabledAutocast(ast.NodeTransformer):
                def visit_With(self, node):
                    self.generic_visit(node)
                    if len(node.items) == 1:
                        call = node.items[0].context_expr
                        if isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute) and call.func.attr == "autocast" and any(k.arg == "enabled" and isinstance(k.value, ast.Constant) and k.value.value is False for k in call.keywords):
                            return node.body
                    return node

            tree = ast.fix_missing_locations(StripDisabledAutocast().visit(ast.parse(body)))
            exec(compile(tree, str(destination), "exec"), module.__dict__)
        else:
            spec.loader.exec_module(module)
        modules.append(module)
    (cache / "source-hashes.json").write_text(json.dumps(hashes, indent=2) + "\n")
    return modules[0], modules[1]


def positions(side: int, text_length: int):
    image = torch.zeros(side * side, 4, device="cpu")
    image[:, 1] = torch.arange(side, device="cpu").repeat_interleave(side) * 0.5
    image[:, 2] = torch.arange(side, device="cpu").repeat(side) * 0.5
    text = torch.zeros(text_length, 4, device="cpu")
    text[:, 3] = torch.arange(text_length, device="cpu")
    return image, text


class InputStage(nn.Module):
    def __init__(self, ref):
        super().__init__()
        self.ref = ref
        h = ref.HIDDEN
        self.emb_in = nn.ModuleDict({"image": nn.Linear(128, h, bias=False)})
        self.txt_in = nn.Linear(20480, h, bias=False)
        self.time_in = ref.MLPEmbedder(256, h)
        self.ref_time_in = ref.MLPEmbedder(256, h)
        self.early_stream_modulations = nn.ModuleDict({m: ref.ModeModulation(h) for m in ["image", "txt"]})
        self.single_stream_modulations = nn.ModuleDict({m: ref.ModeModulation(h) for m in ["image", "txt"]})

    def forward(self, image, text, current_t, target_t):
        reference = self.ref_time_in(self.ref.timestep_embedding(target_t))
        image_vec = self.time_in(self.ref.timestep_embedding(current_t)) + reference
        text_vec = self.time_in(self.ref.timestep_embedding(torch.zeros_like(current_t))) + reference
        early_i = torch.cat(self.early_stream_modulations["image"](image_vec), dim=0)
        early_t = torch.cat(self.early_stream_modulations["txt"](text_vec), dim=0)
        shared_i = torch.cat(self.single_stream_modulations["image"](image_vec), dim=0)
        shared_t = torch.cat(self.single_stream_modulations["txt"](text_vec), dim=0)
        return self.emb_in["image"](image), self.txt_in(text), early_i, early_t, torch.stack((shared_i, shared_t)), image_vec


class DiffusionBlock(nn.Module):
    def __init__(self, block, freqs, image_length=0):
        super().__init__()
        self.block = block
        self.register_buffer("freqs", freqs, persistent=False)
        self.image_length = image_length

    def forward(self, hidden, mods):
        if self.image_length:
            n = self.image_length
            m = hidden.shape[0] - n
            modulation = tuple(torch.cat((mods[0, i:i+1].expand(n, -1), mods[1, i:i+1].expand(m, -1))) for i in range(3))
        else:
            modulation = tuple(mods[i:i+1] for i in range(3))
        return self.block(hidden, self.freqs, [(0, hidden.shape[0])], modulation)


class OutputStage(nn.Module):
    def __init__(self, ref, image_length=1024):
        super().__init__()
        self.final = ref.LastLayer(ref.HIDDEN, 128)
        self.image_length = image_length

    def forward(self, image_hidden, image_vec):
        return self.final(image_hidden[:self.image_length], image_vec).float()


class JoinStage(nn.Module):
    def forward(self, image_hidden, text_hidden):
        return torch.cat((image_hidden, text_hidden), dim=0)


class Decoder(nn.Module):
    def __init__(self, ae_ref):
        super().__init__()
        self.decoder = ae_ref.Decoder()

    def forward(self, spatial_latents):
        return self.decoder(spatial_latents).float()


class TextRMSNorm(nn.Module):
    def __init__(self, dimension):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(dimension))

    def forward(self, hidden):
        values = hidden.float()
        normalized = values * torch.rsqrt(values.square().mean(-1, keepdim=True) + 1e-6)
        return self.weight * normalized.to(hidden.dtype)


class TextAttention(nn.Module):
    def __init__(self):
        super().__init__()
        self.q_proj = nn.Linear(2560, 4096, bias=False)
        self.k_proj = nn.Linear(2560, 1024, bias=False)
        self.v_proj = nn.Linear(2560, 1024, bias=False)
        self.o_proj = nn.Linear(4096, 2560, bias=False)
        self.q_norm = TextRMSNorm(128)
        self.k_norm = TextRMSNorm(128)

    def forward(self, hidden, cos, sin, mask):
        b, length, _ = hidden.shape
        q = self.q_norm(self.q_proj(hidden).reshape(b, length, 32, 128)).transpose(1, 2)
        k = self.k_norm(self.k_proj(hidden).reshape(b, length, 8, 128)).transpose(1, 2)
        v = self.v_proj(hidden).reshape(b, length, 8, 128).transpose(1, 2)
        rotate = lambda x: torch.cat((-x[..., 64:], x[..., :64]), dim=-1)
        q = q * cos.unsqueeze(1) + rotate(q) * sin.unsqueeze(1)
        k = k * cos.unsqueeze(1) + rotate(k) * sin.unsqueeze(1)
        k = k[:, :, None].expand(b, 8, 4, length, 128).reshape(b, 32, length, 128)
        v = v[:, :, None].expand(b, 8, 4, length, 128).reshape(b, 32, length, 128)
        attn = F.scaled_dot_product_attention(q, k, v, attn_mask=mask)
        return self.o_proj(attn.transpose(1, 2).reshape(b, length, 4096))


class TextMLP(nn.Module):
    def __init__(self):
        super().__init__()
        self.gate_proj = nn.Linear(2560, 9728, bias=False)
        self.up_proj = nn.Linear(2560, 9728, bias=False)
        self.down_proj = nn.Linear(9728, 2560, bias=False)

    def forward(self, hidden):
        return self.down_proj(F.silu(self.gate_proj(hidden)) * self.up_proj(hidden))


class TextLayer(nn.Module):
    def __init__(self):
        super().__init__()
        self.input_layernorm = TextRMSNorm(2560)
        self.self_attn = TextAttention()
        self.post_attention_layernorm = TextRMSNorm(2560)
        self.mlp = TextMLP()

    def forward(self, hidden, cos, sin, mask):
        hidden = hidden + self.self_attn(self.input_layernorm(hidden), cos, sin, mask)
        return hidden + self.mlp(self.post_attention_layernorm(hidden))


class TextEmbedding(nn.Module):
    def __init__(self):
        super().__init__()
        self.embed_tokens = nn.Embedding(151936, 2560)

    def forward(self, token_ids):
        return self.embed_tokens(token_ids)


def text_position_inputs(real_tokens, length):
    positions = torch.arange(length, dtype=torch.float32)
    positions[real_tokens:] = 1
    inv_frequency = 1.0 / (5000000 ** (torch.arange(0, 128, 2).float() / 128))
    phases = positions[:, None] * inv_frequency[None]
    phases = torch.cat((phases, phases), dim=-1)[None]
    valid = torch.arange(length)[None, :] <= torch.arange(length)[:, None]
    valid[:, real_tokens:] = False
    mask = torch.where(valid, 0.0, -65504.0)[None, None]
    return phases.cos().half(), phases.sin().half(), mask.half()
