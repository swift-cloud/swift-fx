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
            url: "https://github.com/swift-cloud/swift-fx/releases/download/0.1.0/FXCore.xcframework.zip",
            checksum: "37b06d9ac720ef09968a709816d2538e234429986f040c323b5f4edd0bdbe29a"
        ),
        .target(name: "FX", dependencies: ["CFX"]),
    ]
)
