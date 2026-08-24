// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "swift-fx",
    platforms: [.macOS(.v14), .iOS(.v14)],
    products: [
        .library(name: "FX", targets: ["FX"]),
    ],
    targets: [
        .binaryTarget(
            name: "CFX",
            url: "https://github.com/swift-cloud/swift-fx/releases/download/0.2.0/FXCore.xcframework.zip",
            checksum: "336989dd287a9984f1b921439c642f972ffaf93c1838470c8a9f1f02322ff40e"
        ),
        .target(name: "FX", dependencies: ["CFX"]),
    ]
)
