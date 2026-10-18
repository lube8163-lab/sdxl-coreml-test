"""Reconstruct effective weights from verified CoreAI INT4 bytes, on CPU.

CUDA inference uses FP32 for both variants to isolate weight quantization. The
BF16 scale/product rounding here mirrors the promoted DiT, without requiring a
BF16 CUDA kernel on Volta. Text weights retain their exported FP16 arithmetic.
"""
import hashlib
import json
from pathlib import Path
import numpy as np
from safetensors.numpy import load_file


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        while data := f.read(16 * 1024 * 1024): h.update(data)
    return h.hexdigest()


def round_bf16_inplace(values):
    assert values.dtype == np.float32 and np.isfinite(values).all()
    bits = values.view(np.uint32)
    bits += np.uint32(0x7fff) + ((bits >> 16) & np.uint32(1))
    bits &= np.uint32(0xffff0000)
    return values


class QuantizedComponent:
    def __init__(self, root, name):
        root = Path(root)
        self.receipt = json.loads((root / (name + '.json')).read_text())
        path = root / (name + '.safetensors')
        assert self.receipt['completed'] and sha256(path) == self.receipt['sha256']
        self.arrays = load_file(path)
        self.matrices = {item['name']:item for item in self.receipt['matrices']}
        self.math = 'float16' if name.startswith('te_') else 'bfloat16'

    def weight(self, name, math_dtype=None):
        info = self.matrices[name]
        rows, columns = info['shape']
        packed = self.arrays[name + '.q']
        signed = np.empty(rows * columns, dtype=np.int8)
        signed[0::2] = ((packed & 15).astype(np.int8) << 4) >> 4
        signed[1::2] = packed.view(np.int8) >> 4
        math_dtype = math_dtype or self.math
        scales = self.arrays[name + '.scale']
        if math_dtype == 'float16':
            values = signed.reshape(rows, columns // 32, 32).astype(np.float16)
            values *= scales[..., None]
            return values.reshape(rows, columns).astype(np.float32)
        assert math_dtype == 'bfloat16'
        values = signed.reshape(rows, columns // 32, 32).astype(np.float32)
        scales = round_bf16_inplace(scales.astype(np.float32))
        values *= scales[..., None]
        return round_bf16_inplace(values).reshape(rows, columns)
