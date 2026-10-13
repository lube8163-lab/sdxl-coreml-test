// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalImageGeneration",
    platforms: [.iOS("27.0.1"), .macOS("27.0")],
    products: [
        .library(name: "LocalImageGeneration", targets: ["LocalImageGeneration"]),
        .executable(name: "LocalGenerationSmoke", targets: ["LocalGenerationSmoke"]),
        .executable(name: "LocalGenerationOptimizationCheck", targets: ["LocalGenerationOptimizationCheck"])
    ],
    dependencies: [.package(path: "../MimCoreAIFlux"), .package(path: "../LocalGenerationSafety"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", exact: "0.9.20")],
    targets: [
        .target(name: "LocalImageGeneration", dependencies: [
            .product(name: "CoreAIDiffusion", package: "MimCoreAIFlux"),
            .product(name: "LocalGenerationSafety", package: "LocalGenerationSafety"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ], resources: [.copy("Resources/flux2-catalog-manifest.json"), .copy("Resources/flux2-download-manifest.json")]),
        .executableTarget(name: "LocalGenerationSmoke", dependencies: ["LocalImageGeneration"]),
        .executableTarget(name: "LocalGenerationOptimizationCheck", dependencies: ["LocalImageGeneration"]),
        .testTarget(name: "LocalImageGenerationTests", dependencies: ["LocalImageGeneration",
            .product(name: "CoreAIDiffusion", package: "MimCoreAIFlux")])
    ]
)
