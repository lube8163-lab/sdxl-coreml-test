// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MimCoreAIFlux", platforms: [.macOS("27.0"), .iOS("27.0.1")],
 products: [.library(name: "CoreAIDiffusion", targets: ["CoreAIDiffusionPipeline"])],
 dependencies: [.package(url: "https://github.com/huggingface/swift-transformers", revision: "91286f231bffb9d01998c7e99a8cc760b9e41546")],
 targets: [
 .target(name: "FluxProbeShared", path: "swift/Sources/FluxProbeShared", swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
 .target(name: "CoreAIDiffusionPipeline", dependencies: ["FluxProbeShared", .product(name: "Transformers", package: "swift-transformers")], path: "swift/Sources/CoreAIDiffusionPipeline", swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")])], swiftLanguageModes: [.v6])
