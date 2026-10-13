#!/usr/bin/env python3
"""Import the exact tested model and classifier; weights remain local and untracked."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def copy_verified(source, destination, manifest):
    for entry in manifest["files"]:
        path = (source / entry["path"]).resolve(strict=True)
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
                digest.update(block)
        if path.stat().st_size != entry["bytes"] or digest.hexdigest() != entry["sha256"]:
            raise RuntimeError("Unexpected model asset: " + str(path))
        target = destination / entry["path"]
        if path == target.resolve():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            target.unlink()
        try:
            subprocess.run(["/bin/cp", "-c", str(path), str(target)], check=True)
        except subprocess.CalledProcessError:
            shutil.copyfile(path, target)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--flux-source", required=True, type=Path)
    parser.add_argument("--safety-source", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    flux = json.loads((root / "Vendor/LocalImageGeneration/Sources/LocalImageGeneration/Resources/flux2-catalog-manifest.json").read_text())
    safety = json.loads((root / "scripts/image-safety-source-manifest.json").read_text())
    copy_verified(args.flux_source, root / "artifacts/flux2-klein-4b-512", flux)
    copy_verified(args.safety_source, root / "SDXLCoreMLTest/Resources/ImageSafetyClassifier.mlpackage", safety)
    print("Pinned FLUX bundle and safety classifier prepared.")


if __name__ == "__main__":
    main()
