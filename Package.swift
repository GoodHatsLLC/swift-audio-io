// swift-tools-version: 6.2

import Foundation
import PackageDescription

let package = Package(
  name: "AIO",
  platforms: [.iOS(.v18), .macCatalyst(.v18)],
  products: [
    .library(
      name: "Tools",
      targets: ["Tools"]
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
      url: "https://github.com/apple/swift-collections",
      from: "1.3.0"
    ),
    .package(
      url: "https://github.com/apple/swift-async-algorithms",
      from: "1.1.1"
    ),
    .package(
      url: "https://github.com/apple/swift-atomics",
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
        .enableUpcomingFeature("StrictConcurrency"),
        .strictMemorySafety(),
        .defaultIsolation(.none),
        .enableUpcomingFeature("ExistentialAny"),
      ]
    ),
    .testTarget(
      name: "ToolsTests",
      dependencies: ["Tools"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("StrictConcurrency"),
        .strictMemorySafety(),
        .defaultIsolation(.none),
        .enableUpcomingFeature("ExistentialAny"),
      ]
    ),
    .target(
      name: "AIOEngine",
      dependencies: [
        "Tools",
        "SystemLog",
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "DequeModule", package: "swift-collections"),
        .product(name: "OrderedCollections", package: "swift-collections"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("StrictConcurrency"),
        .strictMemorySafety(),
        .defaultIsolation(.none),

        .enableUpcomingFeature("ExistentialAny"),
      ]
    ),
    .testTarget(
      name: "AIOTests",
      dependencies: ["AIOEngine"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("StrictConcurrency"),
        .strictMemorySafety(),
        .defaultIsolation(.none),
        .enableUpcomingFeature("ExistentialAny"),
      ]
    ),
    .testTarget(
      name: "AudioVisualizationTests",
      dependencies: ["AIOEngine"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("StrictConcurrency"),
        .strictMemorySafety(),
        .defaultIsolation(.none),

        .enableUpcomingFeature("ExistentialAny"),
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
        .enableUpcomingFeature("StrictConcurrency"),
        .strictMemorySafety(),
        .defaultIsolation(.none),
        .enableUpcomingFeature("ExistentialAny"),
      ]
    ),
  ]
)
