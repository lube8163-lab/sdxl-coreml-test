#!/usr/bin/env python3
"""Fetch pinned, hash-checked public BF16 weights into a task-owned directory."""

import argparse
import hashlib
import json
import shutil
import time
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("component", choices=("dit", "text", "vae"))
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
spec = json.loads((Path(__file__).parent / "model-spec.json").read_text())
entry = spec["weights"][args.component]
args.output.mkdir(parents=True, exist_ok=True)
target = args.output / (args.component + ".safetensors")
partial = args.output / (args.component + ".safetensors.partial")
if target.exists():
    raise SystemExit(f"Target already exists; refusing to replace {target}")
base = f"https://huggingface.co/{spec['public_bf16_repository']}/resolve/{spec['public_bf16_revision']}/{entry['file']}"
started = time.monotonic()
last_print = started
for attempt in range(5):
    offset = partial.stat().st_size if partial.exists() else 0
    if offset == entry["size"]:
        break
    if shutil.disk_usage(args.output).free < entry["size"] - offset + 2_000_000_000:
        raise SystemExit("Insufficient free space to download with a 2 GB reserve")
    request = urllib.request.Request(base + f"?download=true&offset={offset}", headers={"Range": f"bytes={offset}-"} if offset else {})
    print(f"{args.component}: downloading from byte {offset} of {entry['size']}", flush=True)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            if offset and (response.status != 206 or not response.headers.get("Content-Range", "").startswith(f"bytes {offset}-")):
                raise RuntimeError("Server did not honor the resume range")
            with partial.open("ab" if offset else "wb") as stream:
                while data := response.read(8 * 1024 * 1024):
                    stream.write(data)
                    offset += len(data)
                    now = time.monotonic()
                    if now - last_print >= 25:
                        print(f"{args.component}: {offset / 1e9:.2f}/{entry['size'] / 1e9:.2f} GB", flush=True)
                        last_print = now
        if offset != entry["size"]:
            raise RuntimeError(f"Unexpected downloaded size: {offset}")
        break
    except Exception as error:
        print(f"Attempt {attempt + 1}: {type(error).__name__}: {error}", flush=True)
        if attempt == 4:
            raise
print(f"{args.component}: verifying SHA-256", flush=True)
digest = hashlib.sha256()
with partial.open("rb") as stream:
    while data := stream.read(16 * 1024 * 1024):
        digest.update(data)
if partial.stat().st_size != entry["size"] or digest.hexdigest() != entry["sha256"]:
    raise SystemExit("Size/SHA-256 mismatch; partial file preserved for inspection")
partial.rename(target)
(args.output / (args.component + "-source.json")).write_text(json.dumps({
    "component": args.component, "source_url": base, "bytes": entry["size"],
    "sha256": digest.hexdigest(), "verified": True,
    "elapsed_seconds": time.monotonic() - started,
}, indent=2) + "\n")
print(f"{args.component}: verified {target}", flush=True)
