#!/usr/bin/env python3
"""Prepare the independent full-generation iPhone app; models transfer separately."""

import argparse
import re
import shutil
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--classifier", required=True, type=Path)
parser.add_argument("--team", required=True)
args = parser.parse_args()
if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
    parser.error("Expected a ten-character development team ID")
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
sources = Path(__file__).resolve().parent
repo = sources.parents[1]
shutil.copyfile(sources / "GenerationProbe.swift", output / "GenerationProbe.swift")
shutil.copytree(args.classifier.resolve(), output / "ImageSafetyClassifier.mlmodelc")
notices = repo / "SDXLCoreMLTest/Resources/ImageSafetyNotices.txt"
shutil.copyfile(notices, output / "ImageSafetyNotices.txt")
(output / "Probe.entitlements").write_text('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.developer.kernel.extended-virtual-addressing</key><true/></dict></plist>
''')
project = f"""name: Flux3GenerationProbe
options:
  deploymentTarget:
    iOS: '27.0.1'
packages:
  LocalGenerationSafety:
    path: {repo / 'Vendor/LocalGenerationSafety'}
settings:
  base:
    DEVELOPMENT_TEAM: {args.team}
    CODE_SIGN_STYLE: Automatic
    CODE_SIGN_ENTITLEMENTS: Probe.entitlements
    SWIFT_VERSION: '5.0'
    TARGETED_DEVICE_FAMILY: '1'
    PRODUCT_BUNDLE_IDENTIFIER: com.tasuku.sdxlcoremltest.flux3generationprobe
    GENERATE_INFOPLIST_FILE: YES
    INFOPLIST_KEY_CFBundleDisplayName: 'FLUX3 生成検証'
    INFOPLIST_KEY_UILaunchScreen_Generation: YES
    CURRENT_PROJECT_VERSION: '1'
    MARKETING_VERSION: '0.1'
targets:
  Flux3GenerationProbe:
    type: application
    platform: iOS
    dependencies:
      - package: LocalGenerationSafety
        product: LocalGenerationSafety
    sources:
      - path: GenerationProbe.swift
      - path: ImageSafetyClassifier.mlmodelc
        type: folder
        buildPhase: resources
      - path: ImageSafetyNotices.txt
        buildPhase: resources
"""
(output / "project.yml").write_text(project)
print(output)
