# Development

This document provides guidelines for contributing to the project, including instructions on how to build, run, and test the project, as well as coding style and commit message format.

## Building and Running

The project includes several scripts in the `bin/` directory to simplify the development process.

### Building the Project

Preferred: use XcodeBuildMCP for workspace/simulator builds (see `DETAILS_BUILD_MCP.md` at repo root).

Backup: build all targets (the `AIOEngine` package and the demo application) with the repo scripts:

```bash
./bin/build.sh
```

To build the package only, you can use the standard Swift build command:

```bash
xcrun swift build
```

### Running Tests

Preferred: use XcodeBuildMCP (from repo root):
```bash
/test-aio
```

Backup: run the full workspace test suite with the repo script (requires a booted iOS simulator):

```bash
./bin/test.sh
```

To run a specific test suite, you can use the `--filter` option:

```bash
xcrun swift test --filter AIOEngineTests
xcrun swift test --filter AudioVisualizationTests
```

To enable code coverage, use the `--enable-code-coverage` option:

```bash
xcrun swift test --enable-code-coverage
```

### Running on Linux

To run tests on Linux, you must set the `NO_PLATFORMS` environment variable:

```bash
NO_PLATFORMS=1 swift build
```

### Running the Demo Application

Preferred: use XcodeBuildMCP (from repo root):
```bash
/run
```

Backup: run the demo application in the iOS simulator with raw Xcode CLI:

```bash
xcodebuild -workspace Recorder.xcworkspace -scheme "Recorder" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

If you need to prepare the iOS simulator, you can use the following script:

```bash
./bin/simulator.sh
```

Alternatively, you can open `Recorder.xcworkspace` in Xcode and run the `Recorder` scheme.

## Code Quality

To format all Swift code according to the project's style guidelines, run the following command:

```bash
./bin/format.sh
```

This is required before committing any changes.

## Contributing

### Coding Style & Naming Conventions

*   Conform to Swift 6.2 idioms with 2-space indentation, 100-character lines, and trailing commas only in multiline argument lists.
*   Name types in UpperCamelCase (`AIOEngine`), methods and variables in lowerCamelCase, and async APIs using verbs plus context (`startRecording`).
*   Run `./bin/format.sh` (swift-format) before committing.
*   Keep shared helpers in `Sources/AIOEngine/Utils` instead of scattering extensions.

### Commit & Pull Request Guidelines

#### Commit Messages

Commits follow the [Conventional Commits](https://www.conventionalcommits.org/) specification: `<type>: <Subject>`.

*   **Types:** `feat`, `fix`, `test`, `docs`, `refactor`
*   **Subject:** Use imperative mood, and keep it under 72 characters.

Example: `feat: add 96kHz sample rate support`

#### Pull Requests

*   State the problem and solution clearly.
*   List verification steps (e.g., `./bin/test.sh`).
*   Attach audio clips or screenshots for signal or UI changes.
*   Link related issues in the footer (`Fixes #123`).
*   Note any configuration or migration impacts.

### Swift Language Requirements

*   **Swift 6.2+** with strict concurrency enabled.
*   **Platforms**: iOS 18.0+, macOS 14.0+.
*   **Dependencies**: swift-async-algorithms, swift-atomics, swift-collections.
*   **Style**: 2-space indent, 100-char lines, UpperCamelCase types, lowerCamelCase methods.
