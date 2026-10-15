#!/usr/bin/env python3
"""Prepare a legacy bundled-assets device experiment in a separate app copy.

Build this copy with LOCAL_FLUX_EMBED_MODELS=YES after preparing local FLUX
assets. This driver measures generation, not the shipping download/onboarding
flow; use prepare_setup_probe.py for that flow. Shipping source is never edited.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess


def replace_once(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise RuntimeError("Unexpected source for " + str(path))
    path.write_text(text.replace(old, new))


def clone(source, destination):
    if destination.exists():
        raise RuntimeError("Probe destination already exists: " + str(destination))
    subprocess.run(["/bin/cp", "-cR", str(source), str(destination)], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--shipping-configuration", action="store_true",
                        help="Keep the original RAM guard, runtime and warm-resource policy.")
    parser.add_argument("--bundle-id", default="com.tasuku.sdxlcoremltest.iphone14probe",
                        help="Separate development bundle ID; never the shipping app's ID.")
    parser.add_argument("--metadata-summary", action="store_true",
                        help="Read function names without GPU model specialization in the copied runtime.")
    parser.add_argument("--transformer-cpu", action="store_true",
                        help="Use the public CPU-only specialization for the copied transformer.")
    parser.add_argument("--frequent-reshapes", action="store_true",
                        help="Test Apple's public reshape-specialization hint on the transformer; implies metadata summary.")
    parser.add_argument("--keep-warm", action="store_true",
                        help="Keep the ordinary warm policy while lowering only the RAM guard in this test copy.")
    parser.add_argument("--extended-virtual-addressing", action="store_true",
                        help="Enable Apple's public extended-address-space entitlement only in the isolated probe.")
    parser.add_argument("--reference-image", type=Path,
                        help="Known benign PNG for a separate real six-view safety check.")
    args = parser.parse_args()
    if not re.fullmatch(r"com\.tasuku\.sdxlcoremltest\.[A-Za-z0-9-]+", args.bundle_id):
        parser.error("Use a separate com.tasuku.sdxlcoremltest.<probe> bundle ID.")
    if args.shipping_configuration and (args.metadata_summary or args.transformer_cpu or args.frequent_reshapes or args.extended_virtual_addressing):
        parser.error("Shipping configuration cannot select experimental runtime or entitlement changes.")
    if args.frequent_reshapes and args.transformer_cpu:
        parser.error("Test GPU reshape specialization and CPU specialization separately.")
    if args.frequent_reshapes:
        args.metadata_summary = True
    root = Path(__file__).resolve().parents[1]
    destination = args.destination.resolve()
    if destination.exists():
        raise RuntimeError("Use a fresh destination; existing probe data is preserved.")
    destination.mkdir(parents=True)
    app = destination / "SDXLCoreMLTest"
    clone(root / "SDXLCoreMLTest", app)
    project = destination / "SDXLCoreMLTest.xcodeproj"
    project.mkdir()
    shutil.copyfile(root / "SDXLCoreMLTest.xcodeproj/project.pbxproj", project / "project.pbxproj")
    for name in ["project.xcworkspace", "xcshareddata"]:
        if (root / "SDXLCoreMLTest.xcodeproj" / name).exists():
            shutil.copytree(root / "SDXLCoreMLTest.xcodeproj" / name, project / name,
                            ignore=shutil.ignore_patterns("xcuserdata"))
    if (root / "LocalImageGenerationUITests").exists():
        clone(root / "LocalImageGenerationUITests", destination / "LocalImageGenerationUITests")
    vendor = destination / "Vendor"
    vendor.mkdir()
    package = vendor / "LocalImageGeneration"
    package.mkdir()
    shutil.copyfile(root / "Vendor/LocalImageGeneration/Package.swift", package / "Package.swift")
    shutil.copyfile(root / "Vendor/LocalImageGeneration/Package.resolved", package / "Package.resolved")
    clone(root / "Vendor/LocalImageGeneration/Sources", package / "Sources")
    clone(root / "Vendor/LocalImageGeneration/Tests", package / "Tests")
    for name in ["LocalGenerationSafety", "StableDiffusionLocal"]:
        (vendor / name).symlink_to(root / "Vendor" / name, target_is_directory=True)
    if args.metadata_summary or args.transformer_cpu or args.frequent_reshapes:
        runtime = vendor / "MimCoreAIFlux"
        shutil.copytree(root / "Vendor/MimCoreAIFlux", runtime,
                        ignore=shutil.ignore_patterns(".git", ".build", "__pycache__", ".DS_Store"))
        model = runtime / "swift/Sources/CoreAIDiffusionPipeline/Components/CoreAIDiffusionModelFunction.swift"
        # Summary lookup is now the production default. Preserve it in probe copies.
        if 'metadata_summary_begin' not in model.read_text():
            raise RuntimeError("Expected production asset-summary metadata lookup")
        if args.transformer_cpu:
            replace_once(model, "let options = SpecializationOptions(preferredComputeUnitKind: .gpu)",
                         'let options: SpecializationOptions = modelURL.lastPathComponent == "Transformer_512.aimodel" ? .cpuOnly : SpecializationOptions(preferredComputeUnitKind: .gpu)')
        elif args.frequent_reshapes:
            replace_once(model, "let options = SpecializationOptions(preferredComputeUnitKind: .gpu)",
                'var options = SpecializationOptions(preferredComputeUnitKind: .gpu)\n        options.expectFrequentReshapes = modelURL.lastPathComponent == "Transformer_512.aimodel"')
    else:
        (vendor / "MimCoreAIFlux").symlink_to(root / "Vendor/MimCoreAIFlux", target_is_directory=True)
    for name in ["artifacts", "scripts"]:
        (destination / name).symlink_to(root / name, target_is_directory=True)

    engine = package / "Sources/LocalImageGeneration/LocalFluxGenerator.swift"
    minimum_match = re.search(r"minimumPhysicalMemoryBytes:\s*UInt64\s*=\s*([\d_]+)", engine.read_text())
    if minimum_match is None:
        raise RuntimeError("Production memory requirement was not found")
    shipping_minimum = int(minimum_match.group(1).replace("_", ""))
    view_model = app / "SDXLGeneratorViewModel.swift"
    replace_once(view_model, "FluxModelPackage.installationDirectory",
                 'Bundle.main.resourceURL!.appendingPathComponent("BundledResources/flux2-klein-4b-512")')
    smoke_source = (root / "scripts/device-probe/PhoneSmoke.swift").read_text()
    if not args.shipping_configuration:
        replace_once(engine, "private let resourcePolicy: GenerationResourcePolicy",
                     "private let resourcePolicy: GenerationResourcePolicy\n    private let allowsLowMemoryProbe: Bool")
        replace_once(engine, "resourcePolicy: GenerationResourcePolicy = .keepWarm) {",
                     "resourcePolicy: GenerationResourcePolicy = .keepWarm, allowsLowMemoryProbe: Bool = false) {")
        replace_once(engine, "self.resourcePolicy = resourcePolicy",
                     "self.resourcePolicy = resourcePolicy\n        self.allowsLowMemoryProbe = allowsLowMemoryProbe")
        replace_once(engine, "guard Self.supportsGeneration else { throw GenerationError.insufficientMemory }",
                     "guard Self.supportsGeneration || (allowsLowMemoryProbe && ProcessInfo.processInfo.physicalMemory >= 5_500_000_000) else { throw GenerationError.insufficientMemory }")
        replace_once(view_model,
            'safetyModelURL: Bundle.main.url(forResource: "ImageSafetyClassifier", withExtension: "mlmodelc"))',
            'safetyModelURL: Bundle.main.url(forResource: "ImageSafetyClassifier", withExtension: "mlmodelc"), resourcePolicy: ' + ('.keepWarm' if args.keep_warm else '.releaseAfterGeneration') + ', allowsLowMemoryProbe: true)')
        smoke_source = smoke_source.replace("private let phoneProbeUsesShippingConfiguration = true",
                                            "private let phoneProbeUsesShippingConfiguration = false")
        if not args.keep_warm:
            smoke_source = smoke_source.replace("private let phoneProbeUsesWarmPolicy = true",
                                                "private let phoneProbeUsesWarmPolicy = false")
        smoke_source = smoke_source.replace("resourcePolicy: .releaseAfterGeneration) // Missing-classifier assertion",
                                            "resourcePolicy: .releaseAfterGeneration, allowsLowMemoryProbe: true) // Missing-classifier assertion")
    sampler = root / "Experiments/FluxMemoryRetest/Sources/MemoryProbeCounters/MemorySampler.swift"
    with view_model.open("a") as stream:
        stream.write("\n" + sampler.read_text() + "\n" + smoke_source)
    bootstrap = app / "SDXLCoreMLTestApp.swift"
    bootstrap.write_text('''import SwiftUI
import UIKit

@main
struct SDXLCoreMLTestApp: App {
    @Environment(\\.scenePhase) private var scenePhase
    @StateObject private var viewModel = SDXLGeneratorViewModel()
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .task {
                    if CommandLine.arguments.contains("--device-smoke") { await viewModel.runDeviceSmoke() }
                    else { viewModel.preloadResourcesIfNeeded() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    viewModel.recordDeviceLifecycle("memory-warning")
                    viewModel.releaseCachedResources(backgrounded: false, allowPreload: false, cancelActiveOperations: false)
                }
                .onChange(of: scenePhase) { _, phase in
                    viewModel.recordDeviceLifecycle("scene-" + String(describing: phase))
                    if phase == .background { viewModel.releaseCachedResources() }
                    else if phase == .active && !CommandLine.arguments.contains("--device-smoke") {
                        viewModel.preloadResourcesIfNeeded()
                    }
                }
        }
    }
}
''')
    info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleDisplayName"] = "ローカル画像生成 検証"
    info_path.write_bytes(plistlib.dumps(info))
    if args.reference_image:
        shutil.copyfile(args.reference_image, app / "Resources/ProbeReference.png")
    text = (project / "project.pbxproj").read_text()
    assert text.count("PRODUCT_BUNDLE_IDENTIFIER = com.tasuku.sdxlcoremltest;") == 2
    text = text.replace("PRODUCT_BUNDLE_IDENTIFIER = com.tasuku.sdxlcoremltest;",
        "PRODUCT_BUNDLE_IDENTIFIER = " + args.bundle_id + ";")
    if args.extended_virtual_addressing:
        (destination / "PhoneProbe.entitlements").write_bytes(plistlib.dumps({
            "com.apple.developer.kernel.extended-virtual-addressing": True
        }))
        text = text.replace("CODE_SIGN_ENTITLEMENTS = SDXLCoreMLTest/SDXLCoreMLTest.entitlements;",
                            "CODE_SIGN_ENTITLEMENTS = PhoneProbe.entitlements;")
    (project / "project.pbxproj").write_text(text)
    baseline_paths = [
        "SDXLCoreMLTest/SDXLGeneratorViewModel.swift", "SDXLCoreMLTest/SDXLCoreMLTestApp.swift",
        "SDXLCoreMLTest/ContentView.swift",
        "Vendor/LocalImageGeneration/Sources/LocalImageGeneration/LocalFluxGenerator.swift",
        "Vendor/LocalGenerationSafety/Sources/LocalGenerationSafety/ImageSafetyChecker.swift",
        "Vendor/MimCoreAIFlux/swift/Sources/CoreAIDiffusionPipeline/Components/CoreAIDiffusionModelFunction.swift",
        "SDXLCoreMLTest/SDXLCoreMLTest.entitlements"
    ]
    (destination / "probe-provenance.json").write_text(json.dumps({
        "shippingSourceSHA256": {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in baseline_paths},
        "probeMinimumMemoryBytes": shipping_minimum if args.shipping_configuration else 5_500_000_000,
        "shippingMinimumMemoryBytes": shipping_minimum,
        "shippingConfiguration": args.shipping_configuration, "bundleID": args.bundle_id,
        "resourcePolicy": "keepWarm" if args.shipping_configuration or args.keep_warm else "releaseAfterGeneration",
        "memorySampling": "50 ms background serial queue; footprint, RSS, lifetime footprint maximum, default-device Metal allocation",
        "expectFrequentReshapes": args.frequent_reshapes,
        "extendedVirtualAddressingRequested": True,
        "copiedEngineMatchesShipping": engine.read_bytes() == (root / "Vendor/LocalImageGeneration/Sources/LocalImageGeneration/LocalFluxGenerator.swift").read_bytes(),
        "copiedViewModelPrefixMatchesShipping": view_model.read_bytes().startswith((root / "SDXLCoreMLTest/SDXLGeneratorViewModel.swift").read_bytes()),
        "assetLocationOverride": "bundled assets for this legacy generation experiment only",
        "steps": 4, "resolution": [512, 512],
        "metadataFunctionLookup": "assetSummary",
        "transformerCompute": "cpuOnly" if args.transformer_cpu else "gpuPreferred",
        "safetyLibrary": "unchanged original package", "sourceRoot": str(root)
    }, indent=2) + "\n")
    print(destination)


if __name__ == "__main__":
    main()
