// swift-tools-version: 6.0
// LocalFlowCore: shared engine for the LocalFlow menu bar app and localflow-cli.
// Builds require xcodebuild (mlx-swift's Metal shaders cannot be compiled by `swift build`).
import PackageDescription

let package = Package(
    name: "LocalFlowCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalFlowCore", targets: ["LocalFlowCore"]),
    ],
    dependencies: [
        // Speech-to-text: Parakeet TDT 0.6B v3 as Core ML (pinned)
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
        // Cleanup LLM: MLX Swift LM (pinned). Pulls mlx-swift 0.32.x + swift-transformers transitively.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        // mlx-swift-lm 3.x no longer bundles the Hub client or tokenizers; we bridge them ourselves (no macros).
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.4"),
    ],
    targets: [
        .target(
            name: "LocalFlowCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/LocalFlowCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LocalFlowCoreTests",
            dependencies: ["LocalFlowCore"],
            path: "Tests/LocalFlowCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
