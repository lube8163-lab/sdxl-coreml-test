#!/usr/bin/env python3
"""Create a Mac experiment copy; shipping runtime/model bytes are never changed."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from prepare_phone_probe import clone, replace_once


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--variant", choices=["baseline", "summary", "reshape"], default="baseline")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    dest = args.destination.resolve()
    if dest.exists():
        parser.error("Choose a fresh destination; prior results are preserved.")
    dest.mkdir(parents=True)
    (dest / "Experiments").mkdir()
    clone(root / "Experiments/FluxMemoryRetest", dest / "Experiments/FluxMemoryRetest")
    (dest / "Vendor").mkdir()
    for name in ["LocalImageGeneration", "MimCoreAIFlux"]:
        shutil.copytree(root / "Vendor" / name, dest / "Vendor" / name,
            ignore=shutil.ignore_patterns(".git", ".build", ".swiftpm", "__pycache__", ".DS_Store"))
    (dest / "Vendor/LocalGenerationSafety").symlink_to(root / "Vendor/LocalGenerationSafety", target_is_directory=True)
    model = dest / "Vendor/MimCoreAIFlux/swift/Sources/CoreAIDiffusionPipeline/Components/CoreAIDiffusionModelFunction.swift"
    if args.variant != "baseline":
        text = model.read_text()
        start = text.index('        let options = SpecializationOptions', text.index('public func hasFunction'))
        end = text.index('        return probe.functionNames.contains(name)', start) + len('        return probe.functionNames.contains(name)')
        model.write_text(text[:start] + '''        FluxProbeEvents.emit("metadata_summary_begin", asset: modelURL.lastPathComponent)
        let asset = try AIModelAsset(contentsOf: modelURL)
        guard let summary = try asset.summary(includingStatistics: false) else { throw CoreAIDiffusionError.notLoaded }
        metadataFunctionNames = summary.functions.map(\\.name)
        FluxProbeEvents.emit("metadata_summary_end", asset: modelURL.lastPathComponent)
        return metadataFunctionNames!.contains(name)''' + text[end:])
    if args.variant == "reshape":
        replace_once(model, "let options = SpecializationOptions(preferredComputeUnitKind: .gpu)",
            'var options = SpecializationOptions(preferredComputeUnitKind: .gpu)\n        options.expectFrequentReshapes = modelURL.lastPathComponent == "Transformer_512.aimodel"')
    paths = ["Vendor/LocalImageGeneration/Sources/LocalImageGeneration/LocalFluxGenerator.swift",
             "Vendor/MimCoreAIFlux/swift/Sources/CoreAIDiffusionPipeline/Components/CoreAIDiffusionModelFunction.swift"]
    (dest / "probe-provenance.json").write_text(json.dumps({
        "scope": "Mac experiment only; identical model files and mandatory six-view generation gate. No six-GB iPhone emulation.",
        "variant": args.variant,
        "shippingSourceSHA256": {p: hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths},
        "probeSourceSHA256": {p: hashlib.sha256((dest/p).read_bytes()).hexdigest() for p in paths},
        "mathematicalModelAndWeightsChanged": False
    }, indent=2) + "\n")
    print(dest)


if __name__ == "__main__":
    main()
