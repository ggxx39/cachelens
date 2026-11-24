// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CacheLens",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CacheLensCore", targets: ["CacheLensCore"]),
        .executable(name: "cachelens", targets: ["CacheLensCLI"]),
        .executable(name: "CacheLensApp", targets: ["CacheLensApp"]),
        .executable(name: "CacheLensSelfTest", targets: ["CacheLensSelfTest"])
    ],
    targets: [
        .target(
            name: "CacheLensCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "CacheLensCLI",
            dependencies: ["CacheLensCore"]
        ),
        .executableTarget(
            name: "CacheLensApp",
            dependencies: ["CacheLensCore"]
        ),
        .executableTarget(
            name: "CacheLensSelfTest",
            dependencies: ["CacheLensCore"]
        ),
        .testTarget(
            name: "CacheLensCoreTests",
            dependencies: ["CacheLensCore"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "CacheLensTests",
            dependencies: ["CacheLensCore"]
        )
    ]
)
