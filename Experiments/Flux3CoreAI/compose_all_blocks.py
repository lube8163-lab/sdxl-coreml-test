#!/usr/bin/env python3
"""Build ordered image/text/shared groups in separate memory-bounded processes."""

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(16 * 1024 * 1024): value.update(chunk)
    return value.hexdigest()

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-root", required=True, type=Path)
parser.add_argument("--output-root", required=True, type=Path)
parser.add_argument("--shared-group-size", type=int, default=4)
args = parser.parse_args()
assert 1 <= args.shared_group_size <= 8
args.output_root.mkdir(parents=True, exist_ok=True)
groups = []
for mode, count, size in [("image", 5, 5), ("text", 5, 5), ("shared", 28, args.shared_group_size)]:
    for index, first in enumerate(range(0, count, size)):
        name = f"{mode}_g{index:02}"
        members = [f"{mode}_{i:02}" for i in range(first, min(first + size, count))]
        receipt_path = args.output_root / (name + ".json")
        if receipt_path.exists():
            receipt = json.loads(receipt_path.read_text())
            assert receipt["completed"] and receipt["members"] == members and receipt["mode"] == mode
            current_sources = []
            for member in members:
                source = json.loads((args.source_root / (member + ".json")).read_text())
                assert source["completed"] and source["compute_dtype"] == "bfloat16"
                hashes = source["asset_files_sha256"]
                for relative, expected in hashes.items():
                    assert digest(args.source_root / (member + ".aimodel") / relative) == expected
                current_sources.append({"component": member, "asset_files_sha256": hashes})
            assert receipt["source_components"] == current_sources, "Existing group uses different source assets; choose a new output root"
            for relative, expected in receipt["asset_files_sha256"].items():
                assert digest(args.output_root / (name + ".aimodel") / relative) == expected
        else:
            subprocess.run([sys.executable, str(Path(__file__).with_name("compose_blocks.py")), name, "--mode", mode, "--members", *members, "--source-root", str(args.source_root), "--output-root", str(args.output_root)], check=True)
            receipt = json.loads(receipt_path.read_text())
        groups.append(receipt)
assert sum(len(g["members"]) for g in groups) == 38
(args.output_root / "groups.json").write_text(json.dumps({"format_version": 1, "groups": groups, "asset_bytes": sum(g["asset_bytes"] for g in groups)}, indent=2) + "\n")
print("Completed", len(groups), "groups,", sum(g["asset_bytes"] for g in groups), "bytes", flush=True)
