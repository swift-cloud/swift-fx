// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "swift-fx",
    platforms: [.macOS(.v14), .iOS(.v14)],
    products: [
        .library(name: "FX", targets: ["FX"]),
        .executable(name: "FXExample", targets: ["FXExample"]),
        .executable(name: "FXTests", targets: ["FXTests"]),
    ],
    targets: [
        .binaryTarget(name: "CFX", path: "Artifacts/FXCore.xcframework"),
        .target(name: "FX", dependencies: ["CFX"]),
        .executableTarget(name: "FXExample", dependencies: ["FX"], path: "Examples/FXExample"),
        .executableTarget(name: "FXTests", dependencies: ["FX"], path: "Tests/FXTests"),
    ]
)
