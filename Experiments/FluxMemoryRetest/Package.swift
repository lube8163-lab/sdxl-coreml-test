// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "FluxMemoryRetest", platforms: [.macOS("27.0"), .iOS("27.0.1")],
    products: [.executable(name: "FluxMemoryRetest", targets: ["FluxMemoryRetest"])],
    dependencies: [.package(path: "../../Vendor/LocalImageGeneration")],
    targets: [
        .target(name: "MemoryProbeCounters"),
        .executableTarget(name: "FluxMemoryRetest", dependencies: ["MemoryProbeCounters",
            .product(name: "LocalImageGeneration", package: "LocalImageGeneration")])])
