#!/usr/bin/env python3
"""Keep the compulsory classifier bundled; download FLUX on first use."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def verify(root, manifest):
    for entry in manifest["files"]:
        path = root / entry["path"]
        if not path.is_file() or path.is_symlink() or path.stat().st_size != entry["bytes"]:
            raise RuntimeError("Missing or invalid model file: " + str(path))
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != entry["sha256"]:
            raise RuntimeError("Model SHA256 mismatch: " + str(path))


def main():
    source_root = Path(os.environ["SRCROOT"])
    app = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
    source = source_root / "artifacts/flux2-klein-4b-512"
    manifest_path = source_root / "Vendor/LocalImageGeneration/Sources/LocalImageGeneration/Resources/flux2-catalog-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest["revision"] != "coreai-512-4bit-a7f65cd-v1" or len(manifest["files"]) != 17:
        raise RuntimeError("Unexpected FLUX manifest")
    safety_manifest = json.loads((source_root / "scripts/image-safety-source-manifest.json").read_text())
    verify(source_root / "SDXLCoreMLTest/Resources/ImageSafetyClassifier.mlpackage", safety_manifest)
    classifier = app / "ImageSafetyClassifier.mlmodelc"
    if not classifier.is_dir() or not (classifier / "coremldata.bin").is_file():
        raise RuntimeError("Mandatory compiled image safety model is missing")
    bundle_root = app / "BundledResources"
    destination = bundle_root / "flux2-klein-4b-512"
    if os.environ.get("LOCAL_FLUX_EMBED_MODELS") != "YES":
        if destination.is_dir():
            shutil.rmtree(destination)
        old_sdxl = bundle_root / "sdxl"
        if old_sdxl.is_dir():
            shutil.rmtree(old_sdxl)
        subprocess.run(["/usr/bin/xattr", "-cr", str(app)], check=True)
        print("Download-on-first-use build: FLUX weights excluded; mandatory safety classifier present.")
        return
    verify(source, manifest)
    if os.environ.get("PLATFORM_NAME") == "iphonesimulator":
        # CoreAI is compiled out on Simulator. UI verification needs only the safety model;
        # it never produces mock images or uses a different generation backend.
        subprocess.run(["/usr/bin/xattr", "-cr", str(app)], check=True)
        print("Simulator UI build: mandatory safety classifier present; CoreAI generation unavailable.")
        return
    destination.mkdir(parents=True, exist_ok=True)
    for entry in manifest["files"]:
        target = destination / entry["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            target.unlink()
        # APFS clones save space on the 8GB development Mac. The app contains real files.
        try:
            subprocess.run(["/bin/cp", "-c", str(source / entry["path"]), str(target)], check=True)
        except subprocess.CalledProcessError:
            shutil.copyfile(source / entry["path"], target)
    old_sdxl = bundle_root / "sdxl"
    if old_sdxl.is_dir():
        shutil.rmtree(old_sdxl)
    subprocess.run(["/usr/bin/xattr", "-cr", str(app)], check=True)
    print("Embedded 17 SHA256-verified FLUX files and mandatory image safety classifier.")


if __name__ == "__main__":
    main()
