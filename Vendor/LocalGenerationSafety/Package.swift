// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalGenerationSafety",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "LocalGenerationSafety", targets: ["LocalGenerationSafety"]),
               .executable(name: "SafetyClassifierProbe", targets: ["SafetyClassifierProbe"])],
    targets: [
        .target(name: "LocalGenerationSafety", resources: [.copy("Resources/ContentSafetyPolicy.json")]),
        .testTarget(name: "LocalGenerationSafetyTests", dependencies: ["LocalGenerationSafety"]),
        .executableTarget(name: "SafetyClassifierProbe", dependencies: ["LocalGenerationSafety"])
    ]
)
