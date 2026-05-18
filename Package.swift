// swift-tools-version: 6.3

import Foundation
import PackageDescription

func swiftSettings(_ settings: PackageDescription.SwiftSetting...) -> [PackageDescription
  .SwiftSetting]
{
  [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    .defaultIsolation(.none),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  ] + settings
}

let package = Package(
  name: "AIO",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(
      name: "Tools",
      targets: ["Tools"],
    ),
    .library(
      name: "AudioSignals",
      targets: ["AudioSignals"],
    ),
    .library(
      name: "AIOEngine",
      targets: ["AIOEngine"],
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-collections.git",
      from: "1.3.0",
    ),
    .package(
      url: "https://github.com/apple/swift-async-algorithms.git",
      from: "1.1.1",
    ),
    .package(
      url: "https://github.com/apple/swift-atomics.git",
      from: "1.3.0",
    ),
  ],
  targets: [
    .target(
      name: "Tools",
      dependencies: [
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "DequeModule", package: "swift-collections"),
        .product(name: "OrderedCollections", package: "swift-collections"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .testTarget(
      name: "ToolsTests",
      dependencies: ["Tools"],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AudioSignals",
      dependencies: [
        "Tools",
        .product(name: "Atomics", package: "swift-atomics"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIOContracts",
      dependencies: [],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIOSupport",
      dependencies: [],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIOAudioSession",
      dependencies: [
        "AIOContracts",
        "AIOSupport",
        "Tools",
      ],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIOVisualization",
      dependencies: [
        "AIOContracts",
        "AIOSupport",
        "AudioSignals",
        "Tools",
        .product(name: "Atomics", package: "swift-atomics"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIOEngineCore",
      dependencies: [
        "AIOAudioSession",
        "AIOContracts",
        "AIORecordingSupport",
        "AIOSupport",
        "Tools",
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "Atomics", package: "swift-atomics"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIORecording",
      dependencies: [
        "AIOAudioSession",
        "AIOContracts",
        "AIOEngineCore",
        "AIORecordingSupport",
        "AIOSupport",
        "Tools",
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "Atomics", package: "swift-atomics"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIORecordingSupport",
      dependencies: [
        "AIOAudioSession",
        "Tools",
        .product(name: "Atomics", package: "swift-atomics"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIOPlayback",
      dependencies: [
        "AIOAudioSession",
        "AIOEngineCore",
        "AIOSupport",
        "Tools",
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIOMicHealth",
      dependencies: [
        "AIOAudioSession",
        "Tools",
      ],
      swiftSettings: swiftSettings(),
    ),
    .target(
      name: "AIOEngine",
      dependencies: [
        "AIOAudioSession",
        "AIOContracts",
        "AIOEngineCore",
        "AIOMicHealth",
        "AIOPlayback",
        "AIORecording",
        "AIORecordingSupport",
        "AIOSupport",
        "AIOVisualization",
        "Tools",
        "AudioSignals",
        .product(name: "Atomics", package: "swift-atomics"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .testTarget(
      name: "AIOTests",
      dependencies: ["AIOAudioSession", "AIOEngine", "AIORecordingSupport"],
      swiftSettings: swiftSettings(),
    ),
    .testTarget(
      name: "AudioVisualizationTests",
      dependencies: ["AIOEngine", "AudioSignals"],
      swiftSettings: swiftSettings(),
    ),
    .testTarget(
      name: "AIOMicHealthTests",
      dependencies: ["AIOAudioSession", "AIOMicHealth"],
      swiftSettings: swiftSettings(),
    ),
  ],
)
