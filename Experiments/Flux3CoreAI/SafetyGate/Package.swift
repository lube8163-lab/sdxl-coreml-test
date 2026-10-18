// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Flux3ResearchSafetyGate",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "flux3-safety-gate", targets: ["SafetyGate"])],
    dependencies: [.package(path: "../../../Vendor/LocalGenerationSafety")],
    targets: [.executableTarget(name: "SafetyGate", dependencies: [.product(name: "LocalGenerationSafety", package: "LocalGenerationSafety")])]
)
