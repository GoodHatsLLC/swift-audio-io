// swift-tools-version: 6.2

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
      name: "AIOEngine",
      dependencies: [
        "Tools",
        "AudioSignals",
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "DequeModule", package: "swift-collections"),
        .product(name: "OrderedCollections", package: "swift-collections"),
      ],
      swiftSettings: swiftSettings(),
    ),
    .testTarget(
      name: "AIOTests",
      dependencies: ["AIOEngine"],
      swiftSettings: swiftSettings(),
    ),
    .testTarget(
      name: "AudioVisualizationTests",
      dependencies: ["AIOEngine", "AudioSignals"],
      swiftSettings: swiftSettings(),
    ),
  ],
)
