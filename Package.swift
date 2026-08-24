// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-fx",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FX", targets: ["FX"]),
    ],
    targets: [
        .binaryTarget(
            name: "CFX",
            url: "https://github.com/swift-cloud/swift-fx/releases/download/0.1.0/FXCore.xcframework.zip",
            checksum: "9e5182277b568b5b7144c120273d968a1debbd250896b4090b5c965b46b9d7e6"
        ),
        .target(name: "FX", dependencies: ["CFX"]),
    ]
)
