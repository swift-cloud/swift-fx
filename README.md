# swift-fx

Swift bindings for [fx](https://github.com/vercel-labs/fx), a tiny native coding agent. The package embeds fx as a prebuilt universal macOS XCFramework and exposes a Swift concurrency API.

## Requirements

- macOS 14 or later
- Swift 6.2 or later
- A Vercel AI Gateway API key

## Installation

Add the package dependency:

```swift
.package(url: "https://github.com/swift-cloud/swift-fx.git", from: "0.1.0")
```

Then add `FX` to your target dependencies:

```swift
.product(name: "FX", package: "swift-fx")
```

Consumers do not need Zig or Xcode beyond the normal Swift toolchain. SwiftPM downloads the release XCFramework whose checksum is pinned in `Package.swift`.

## Usage

```swift
import Foundation
import FX

let agent = try await FXAgent(
    configuration: .init(
        apiKey: ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"]!,
        workspace: URL(fileURLWithPath: "/path/to/project")
    ),
    permissionHandler: { _ in .deny }
)

let session = try await agent.createSession()
let turn = try await session.prompt("Explain this project")

for try await update in turn.updates {
    if case .assistantText(let text) = update {
        print(text, terminator: "")
    }
}

print(try await turn.stopReason)
await agent.close()
```

Call `FXTurn.cancel()` to cancel an active turn. `FXAgent` and `FXSession` are actors.

The initial release is headless and intentionally disables native tools and MCP. It supports durable sessions, streaming turns, model and mode configuration, cancellation, permission requests, and host-owned networking through `URLSession`.

## Development

`FX_REVISION` pins the upstream fx commit. `Patches/fx-c-api.patch` adds the native C ABI used by Swift until that surface is available upstream.

Build and test a local XCFramework:

```sh
brew install zig
Scripts/build-xcframework.sh
cp Package.swift /tmp/Package.release.swift
trap 'mv /tmp/Package.release.swift Package.swift' EXIT
Scripts/use-local-artifact.sh
swift run FXTests
```

## Releases

Run the `Release` workflow with a semantic version such as `0.1.0`. The workflow:

1. Builds arm64 and x86_64 macOS archives from the pinned fx revision.
2. Creates and smoke-tests `FXCore.xcframework` through a local binary target.
3. Computes the SwiftPM checksum.
4. Updates `Package.swift` to the versioned release URL and checksum.
5. Commits that manifest, creates the version tag, and publishes the exact tested archive.

The release workflow is atomic: the tag, manifest checksum, and uploaded archive all belong to the same workflow run.

## License

Apache-2.0. See `NOTICE` for embedded fx attribution.
