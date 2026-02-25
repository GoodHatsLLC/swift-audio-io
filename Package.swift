// swift-tools-version: 6.2

import Foundation
import PackageDescription

let package = Package(
  name: "AIO",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(
      name: "Tools",
      targets: ["Tools"]
    ),
    .library(
      name: "AudioSignals",
      targets: ["AudioSignals"]
    ),
    .library(
      name: "AIOEngine",
      targets: ["AIOEngine"]
    ),
    .library(
      name: "SystemLog",
      targets: ["SystemLog"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-collections.git",
      from: "1.3.0"
    ),
    .package(
      url: "https://github.com/apple/swift-async-algorithms.git",
      from: "1.1.1"
    ),
    .package(
      url: "https://github.com/apple/swift-atomics.git",
      from: "1.3.0"
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
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .strictMemorySafety(),
        .defaultIsolation(.none),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
      ]
    ),
    .testTarget(
      name: "ToolsTests",
      dependencies: ["Tools"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .strictMemorySafety(),
        .defaultIsolation(.none),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
      ]
    ),
    .target(
      name: "AudioSignals",
      dependencies: [
        "Tools",
        "SystemLog",
        .product(name: "Atomics", package: "swift-atomics"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .strictMemorySafety(),
        .defaultIsolation(.none),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
      ]
    ),
    .target(
      name: "AIOEngine",
      dependencies: [
        "Tools",
        "AudioSignals",
        "SystemLog",
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "DequeModule", package: "swift-collections"),
        .product(name: "OrderedCollections", package: "swift-collections"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .strictMemorySafety(),
        .defaultIsolation(.none),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
      ]
    ),
    .testTarget(
      name: "AIOTests",
      dependencies: ["AIOEngine"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .strictMemorySafety(),
        .defaultIsolation(.none),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
      ]
    ),
    .testTarget(
      name: "AudioVisualizationTests",
      dependencies: ["AIOEngine", "AudioSignals"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .strictMemorySafety(),
        .defaultIsolation(.none),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
      ]
    ),
    .target(
      name: "SystemLog",
      dependencies: [
        "Tools",
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "DequeModule", package: "swift-collections"),
        .product(name: "OrderedCollections", package: "swift-collections"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .strictMemorySafety(),
        .defaultIsolation(.none),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
      ]
    ),
  ]
)
