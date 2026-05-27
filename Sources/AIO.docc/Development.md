# Development

Use SwiftPM for AIO package work:

```bash
xcrun swift build --package-path Packages/AIO
xcrun swift test --package-path Packages/AIO
```

CircleCI's `build-test` workflow runs the broader AIO gate on every push: the
SwiftPM package tests on the macOS host, plus the workspace-only
`AIOPlatformIntegrationTests` iOS Simulator scheme and the `AIOHarnessiOSUITests` /
`AIOHarnessMacUITests` real-platform harness suites. To reproduce that locally:

```bash
./bin/test.sh --all   # SwiftPM unit tests + iOS Simulator + macOS workspace schemes
```

## Quickstart Rot Check

The public quickstart in `Packages/AIO/README.md` is mirrored by
`Tests/AIOTests/AIOQuickstart.swift`. The mirrored file imports only `AudioIO` and is
compiled by the AIO package test suite so API drift breaks CI instead of documentation.

To run only that check:

```bash
xcrun swift test --package-path Packages/AIO --filter AIOQuickstartTests
```

## Style

- Swift 6.2 with strict concurrency.
- Prefer typed errors for public engine operations.
- Public initializers that accept user-controlled values must not trap; add throwing
  validation or explicit clamping paths.
- Keep realtime callback work allocation-free and non-blocking.
- Run `swift-format` or `bin/format.sh` before committing.
