#!/usr/bin/env python3
"""Read-only Windows/V100 readiness probe; installs nothing and downloads no models."""

import importlib.metadata
import json
import platform
import shutil
import subprocess
import sys

report = {"platform": platform.platform(), "python": sys.version, "packages": {}}
for package in ["torch", "safetensors", "transformers", "accelerate", "coreai-torch", "coreai-core"]:
    try: report["packages"][package] = importlib.metadata.version(package)
    except importlib.metadata.PackageNotFoundError: report["packages"][package] = None
binary = shutil.which("nvidia-smi")
report["nvidia_smi_found"] = binary is not None
if binary:
    try:
        result = subprocess.run([binary, "--query-gpu=name,memory.total,driver_version", "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=20)
        report["nvidia_smi"] = {"returncode": result.returncode, "gpu_rows": result.stdout.strip().splitlines(), "error": result.stderr.strip()}
    except Exception as error: report["nvidia_smi_error"] = str(error)
if report["packages"]["torch"]:
    try:
        import torch
        report["torch_cuda_version"] = torch.version.cuda
        report["cuda_available"] = torch.cuda.is_available()
        if report["cuda_available"]:
            report["pytorch_compiled_arches"] = torch.cuda.get_arch_list()
            report["gpus"] = [{"name": torch.cuda.get_device_name(i), "capability": list(torch.cuda.get_device_capability(i)), "memory_bytes": torch.cuda.get_device_properties(i).total_memory} for i in range(torch.cuda.device_count())]
            try:
                values = torch.randn((256, 256), device="cuda", dtype=torch.float16) * .1
                result = values @ values.T
                torch.cuda.synchronize()
                report["small_fp16_matmul_finite"] = bool(torch.isfinite(result).all())
            except Exception as error: report["small_fp16_matmul_error"] = str(error)
    except Exception as error: report["torch_error"] = str(error)
print(json.dumps(report, ensure_ascii=False, indent=2))
