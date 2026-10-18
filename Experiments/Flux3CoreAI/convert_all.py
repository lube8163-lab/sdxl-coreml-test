#!/usr/bin/env python3
"""Run component exports sequentially in fresh Python processes."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("group", choices=["dit", "text", "vae"])
parser.add_argument("--work", required=True, type=Path)
parser.add_argument("--compute-dtype", choices=["float16", "bfloat16"], default="float16")
parser.add_argument("--output-root", type=Path)
args = parser.parse_args()
work = args.work.resolve()
length = json.loads((work / "fixture/caption.json").read_text())["text_length"]
groups = {
    "dit": ["input", "join"] + [f"image_{i:02}" for i in range(5)] + [f"text_{i:02}" for i in range(5)] + [f"shared_{i:02}" for i in range(28)] + ["output"],
    "text": ["te_embed"] + [f"te_{i:02}" for i in range(32)],
    "vae": ["vae"],
}
script = Path(__file__).parent / "convert_component.py"
output = args.output_root.resolve() if args.output_root else work / "coreai"
log_dir = work / ("conversion-logs" if args.output_root is None else "conversion-logs-" + output.name)
log_dir.mkdir(exist_ok=True)
for index, component in enumerate(groups[args.group]):
    print(f"[{args.group} {index+1}/{len(groups[args.group])}] {component}", flush=True)
    with (log_dir / (component + ".log")).open("a") as log:
        result = subprocess.run([sys.executable, str(script), component, "--work", str(work), "--text-length", str(length), "--compute-dtype", args.compute_dtype, "--output-root", str(output)], stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((log_dir / (component + ".log")).read_text()[-12000:], flush=True)
        raise SystemExit(result.returncode)
    receipt = json.loads((output / (component + ".json")).read_text())
    print(f"  {receipt['asset_bytes']/1e6:.1f} MB; peak RSS {receipt['max_rss_bytes']/1e9:.2f} GB; {receipt['elapsed_seconds']:.1f}s", flush=True)
print(args.group, "exports completed", flush=True)
