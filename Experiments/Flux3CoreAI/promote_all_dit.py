#!/usr/bin/env python3
"""Promote each DiT graph in a fresh process, retaining existing text/VAE assets."""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--work", required=True, type=Path)
parser.add_argument("--output-root", required=True, type=Path)
args = parser.parse_args()
source = args.work / "coreai"
plan = json.loads((source / "model-plan.json").read_text())
script = Path(__file__).with_name("promote_dit_precision.py")
args.output_root.mkdir(parents=True, exist_ok=True)
components = [c for c in plan["components"] if c["source_weight_file"] == "dit"]
assert len(components) == 41
for index, item in enumerate(components):
    print(f"[BF16 {index+1}/41]", item["component"], flush=True)
    subprocess.run([sys.executable, str(script), item["component"], "--work", str(args.work), "--output-root", str(args.output_root)], check=True)
for item in plan["components"]:
    if item["source_weight_file"] == "dit":
        continue
    name = item["component"]
    destination = args.output_root / (name + ".aimodel")
    if not destination.exists():
        shutil.copytree(source / destination.name, destination, copy_function=os.link)
    receipt_path = args.output_root / (name + ".json")
    if not receipt_path.exists():
        shutil.copyfile(source / receipt_path.name, receipt_path)
print("41 DiT graphs promoted; 34 original text/VAE components retained", flush=True)
