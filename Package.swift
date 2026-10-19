// swift-tools-version:6.0
import PackageDescription

// DictateCore is pure Foundation (no AppKit) so it tests headless.
// DictateAppKit holds every AppKit/AVFoundation/CoreGraphics piece; DictateApp
// is the thin executable that boots it.
let package = Package(
    name: "Dictate",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DictateKit", targets: ["DictateCore", "DictateAppKit"]),
        .executable(name: "Dictate", targets: ["DictateApp"]),
    ],
    targets: [
        .target(name: "DictateObjC"),
        .target(name: "DictateCore", dependencies: ["DictateObjC"]),
        .target(name: "DictateAppKit", dependencies: ["DictateCore"]),
        .executableTarget(name: "DictateApp", dependencies: ["DictateAppKit"]),
        // G6 latency harness + cleanup-model measurement (network; never run by `swift test`).
        .executableTarget(name: "DictateBench", dependencies: ["DictateCore", "DictateAppKit"]),
        .testTarget(name: "DictateCoreTests", dependencies: ["DictateCore", "DictateObjC", "DictateAppKit"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "DictateAppKitTests", dependencies: ["DictateAppKit"]),
    ],
    swiftLanguageModes: [.v5]
)
