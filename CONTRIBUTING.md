# Contributing

Install Zig 0.16 or later and full Xcode. Run:

```sh
Scripts/build-xcframework.sh
cp Package.swift /tmp/Package.release.swift
trap 'mv /tmp/Package.release.swift Package.swift' EXIT
Scripts/use-local-artifact.sh
swift build
swift run FXTests
Scripts/test-ios-simulator.sh
```

When updating fx, change `FX_REVISION`, regenerate `Patches/fx-c-api.patch` against that exact commit, and rerun the full local binary-target test.
