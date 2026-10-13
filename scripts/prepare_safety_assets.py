#!/usr/bin/env python3
"""Fetch the pinned, compulsory Core ML safety package before building the app."""
import hashlib
import json
from pathlib import Path
import urllib.request


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main():
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "scripts/image-safety-source-manifest.json").read_text())
    revision = "1d6482987f783eb431458a2501cd6f59db6c8e6d"
    destination = root / "SDXLCoreMLTest/Resources/ImageSafetyClassifier.mlpackage"
    for entry in manifest["files"]:
        target = destination / entry["path"]
        if target.is_file() and target.stat().st_size == entry["bytes"] and digest(target) == entry["sha256"]:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_name(target.name + ".download")
        url = "https://huggingface.co/InspiratioNULL/image-safety-classifier-s-CoreML/resolve/" + revision + "/ImageSafetyClassifier.mlpackage/" + entry["path"]
        try:
            with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as output:
                received = 0
                while chunk := response.read(1024 * 1024):
                    received += len(chunk)
                    if received > entry["bytes"]:
                        raise RuntimeError("Unexpected safety package size")
                    output.write(chunk)
            if temporary.stat().st_size != entry["bytes"] or digest(temporary) != entry["sha256"]:
                raise RuntimeError("Safety package checksum mismatch")
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    print("Mandatory safety package verified (MIT; SwiftFormer Apache-2.0).")


if __name__ == "__main__":
    main()
