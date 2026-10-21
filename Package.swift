// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MKSoundEditor",
    platforms: [
        // .v14 so the #Preview macro (macOS 14+) is available in the UI targets.
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MKSoundEditor", targets: ["MKSoundEditor"]),
        .executable(name: "SmokeTest", targets: ["SmokeTest"]),
    ],
    targets: [
        // Core PBAPI module - MIDI communication layer
        .target(
            name: "PBAPI",
            dependencies: [],
            path: "Sources/PBAPI"
        ),
        // Data models module
        .target(
            name: "Models",
            dependencies: ["PBAPI"],
            path: "Sources/Models"
        ),
        // UI views layer
        .target(
            name: "UIViews",
            dependencies: ["Models", "PBAPI"],
            path: "Sources/UI/Views"
        ),
        // UI controllers layer
        .target(
            name: "UIControllers",
            dependencies: ["UIViews", "PBAPI", "Models"],
            path: "Sources/UI/Controllers"
        ),
        // Utilities module
        .target(
            name: "Utilities",
            dependencies: ["PBAPI"],
            path: "Sources/Utilities"
        ),
        // Main executable - depends on all modules
        .executableTarget(
            name: "MKSoundEditor",
            dependencies: [
                "PBAPI",
                "Models",
                "UIViews",
                "UIControllers",
                "Utilities"
            ]
        ),
        // Hardware smoke test CLI (endpoints + SysEx round-trip hexdump)
        .executableTarget(
            name: "SmokeTest",
            dependencies: ["PBAPI", "Models"],
            path: "Sources/SmokeTest"
        ),
        // SysEx framing / codec regression tests
        .testTarget(
            name: "PBAPITests",
            dependencies: ["PBAPI"],
            path: "Tests/PBAPITests"
        ),
        // Program parameter-map regression tests (TABLE 1/2 offsets)
        .testTarget(
            name: "ModelsTests",
            dependencies: ["Models", "PBAPI"],
            path: "Tests/ModelsTests"
        ),
        // Rendered-layout probes for SwiftUI views (bank browser grid, etc.)
        .testTarget(
            name: "UIViewsTests",
            dependencies: ["UIViews", "Models", "PBAPI"],
            path: "Tests/UIViewsTests"
        ),
        // Window/bank-state controller regression tests (import merge, etc.)
        .testTarget(
            name: "UIControllersTests",
            dependencies: ["UIControllers", "Models", "PBAPI"],
            path: "Tests/UIControllersTests"
        ),
    ]
)
