#!/usr/bin/env python3
"""Prepare an isolated app copy whose startup driver exercises the real setup/VM.

No test hooks are added to shipping source. The default bundle has independent
storage and downloads the model again; an explicit --bundle-id may reuse an
existing development installation and its owned model data.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--bundle-id", default="com.tasuku.sdxlcoremltest.setupprobe")
    args = parser.parse_args()
    if not re.fullmatch(r"com\.tasuku\.sdxlcoremltest(?:\.[A-Za-z0-9-]+)?", args.bundle_id):
        parser.error("Use this app's development bundle ID or a probe suffix.")
    root = Path(__file__).resolve().parents[1]
    dest = args.destination.resolve()
    if dest.exists():
        parser.error("Use a fresh destination; existing files are preserved.")
    dest.mkdir(parents=True)
    for name in ["SDXLCoreMLTest", "LocalImageGenerationUITests"]:
        subprocess.run(["/bin/cp", "-cR", str(root / name), str(dest / name)], check=True)
    shutil.copytree(root / "SDXLCoreMLTest.xcodeproj", dest / "SDXLCoreMLTest.xcodeproj",
                    ignore=shutil.ignore_patterns("xcuserdata", "*.xcuserstate"))
    for name in ["Vendor", "scripts"]:
        (dest / name).symlink_to(root / name, target_is_directory=True)
    app = dest / "SDXLCoreMLTest/SDXLCoreMLTestApp.swift"
    source = app.read_text()
    target = ".task {\n                    if welcomeCompleted { setup.inspectInstallation() }\n                }"
    if source.count(target) != 1:
        raise RuntimeError("Unexpected shipping bootstrap; inspect before changing the driver.")
    source = source.replace(target, '''.task {
                    if CommandLine.arguments.contains("--setup-validation") {
                        SetupValidation.start(self)
                    } else if welcomeCompleted { setup.inspectInstallation() }
                }''')
    app.write_text(source + "\n" + (root / "scripts/device-probe/SetupValidation.swift").read_text())
    project = dest / "SDXLCoreMLTest.xcodeproj/project.pbxproj"
    project.write_text(project.read_text().replace("PRODUCT_BUNDLE_IDENTIFIER = com.tasuku.sdxlcoremltest;",
                                                  "PRODUCT_BUNDLE_IDENTIFIER = " + args.bundle_id + ";"))
    paths = ["SDXLCoreMLTest/SDXLCoreMLTestApp.swift", "SDXLCoreMLTest/ModelSetupViewModel.swift",
             "SDXLCoreMLTest/SDXLGeneratorViewModel.swift",
             "Vendor/LocalImageGeneration/Sources/LocalImageGeneration/LocalFluxGenerator.swift",
             "Vendor/LocalImageGeneration/Sources/LocalImageGeneration/FluxModelPackage.swift"]
    (dest / "probe-provenance.json").write_text(json.dumps({
        "scope": "Startup automation calls production setup and generation methods; it is not an XCTest UI run.",
        "bundleID": args.bundle_id,
        "shippingSourceSHA256": {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in paths},
        "engineAndInstallerUnchanged": True,
        "bundledGenerationModels": False,
        "minimumMemoryBytes": 7_500_000_000, "steps": 4, "resolution": [512, 512]
    }, indent=2) + "\n")
    print(dest)


if __name__ == "__main__":
    main()
