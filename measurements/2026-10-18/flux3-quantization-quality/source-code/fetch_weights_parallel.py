#!/usr/bin/env python3
"""Resume a pinned BF16 download using bounded HTTP ranges and positional writes.

Only the single partial file is allocated. A persistent range ledger makes an
interrupted parallel download resumable; whole-file SHA-256 remains mandatory.
Do not run another downloader against the same target concurrently.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import shutil
import threading
import time
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("component", choices=["dit", "text", "vae"])
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--workers", type=int, default=6)
args = parser.parse_args()
assert 1 <= args.workers <= 8
spec = json.loads((Path(__file__).parent / "model-spec.json").read_text())
entry = spec["weights"][args.component]
args.output.mkdir(parents=True, exist_ok=True)
target = args.output / (args.component + ".safetensors")
partial = args.output / (args.component + ".safetensors.partial")
ledger_path = args.output / (args.component + ".ranges.json")
assert not target.exists(), "Refusing to replace an existing final checkpoint"
url = f"https://huggingface.co/{spec['public_bf16_repository']}/resolve/{spec['public_bf16_revision']}/{entry['file']}"
started = time.monotonic()
if ledger_path.exists():
    ledger = json.loads(ledger_path.read_text())
    assert ledger["url"] == url and ledger["sha256"] == entry["sha256"]
    assert partial.stat().st_size == entry["size"]
else:
    prefix = partial.stat().st_size if partial.exists() else 0
    assert prefix <= entry["size"]
    assert shutil.disk_usage(args.output).free > entry["size"] - prefix + 2_000_000_000
    ledger = {"url": url, "sha256": entry["sha256"], "prefix_bytes": prefix, "completed": []}
    ledger_path.write_text(json.dumps(ledger, indent=2) + "\n")
with partial.open("ab") as allocation:
    allocation.truncate(entry["size"])
chunk_size = 128 * 1024 * 1024
chunks = [(offset, min(entry["size"] - 1, offset + chunk_size - 1)) for offset in range(ledger["prefix_bytes"], entry["size"], chunk_size)]
done = set(ledger["completed"])
lock = threading.Lock()

def fetch(bounds):
    start, end = bounds
    if start in done:
        return
    for attempt in range(5):
        try:
            request = urllib.request.Request(url + f"?download=true&range={start}-{end}", headers={"Range": f"bytes={start}-{end}"})
            # A separate file handle per worker also supports Windows, where
            # os.pwrite is unavailable. Each handle has its own file cursor.
            with urllib.request.urlopen(request, timeout=45) as response, partial.open("r+b", buffering=0) as output:
                assert response.status == 206
                assert response.headers.get("Content-Range") == f"bytes {start}-{end}/{entry['size']}"
                cursor = start
                output.seek(start)
                while data := response.read(2 * 1024 * 1024):
                    assert cursor + len(data) <= end + 1
                    view = memoryview(data)
                    while view:
                        written = output.write(view)
                        assert written > 0
                        cursor += written
                        view = view[written:]
                assert cursor == end + 1
                os.fsync(output.fileno())
            with lock:
                done.add(start)
                ledger["completed"] = sorted(done)
                temp = ledger_path.with_suffix(".json.tmp")
                temp.write_text(json.dumps(ledger, indent=2) + "\n")
                temp.replace(ledger_path)
                total = ledger["prefix_bytes"] + sum(b-a+1 for a,b in chunks if a in done)
                print(f"{args.component}: {total/1e9:.2f}/{entry['size']/1e9:.2f} GB, {len(done)}/{len(chunks)} ranges", flush=True)
            return
        except Exception as error:
            print(f"Range {start}-{end}, attempt {attempt+1}: {error!r}", flush=True)
            if attempt == 4:
                raise

with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
    list(executor.map(fetch, chunks))
print("Verifying whole-file SHA-256", flush=True)
digest = hashlib.sha256()
with partial.open("rb") as stream:
    while data := stream.read(16 * 1024 * 1024):
        digest.update(data)
assert digest.hexdigest() == entry["sha256"], "SHA-256 mismatch; partial and range ledger retained"
partial.rename(target)
(args.output / (args.component + "-source.json")).write_text(json.dumps({"component": args.component, "source_url": url, "bytes": entry["size"], "sha256": digest.hexdigest(), "verified": True, "elapsed_seconds": time.monotonic()-started, "parallel_workers": args.workers}, indent=2) + "\n")
print("Verified", target, flush=True)
