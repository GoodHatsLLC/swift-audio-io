// swift-tools-version: 6.2

import Foundation
import PackageDescription

enum Platforms {
  static var apple: [PackageDescription.SupportedPlatform]? {
    if ProcessInfo.processInfo.environment["NO_PLATFORMS"] == nil {
      [
        .iOS(.v18),
        .macOS(.v15),
      ]
    } else {
      nil
    }
  }
}

let package = Package(
  name: "AIO",
  platforms: Platforms.apple,
  products: [
    .library(
      name: "Tools",
      targets: ["Tools"]
    ),
    .library(
      name: "AIOEngine",
      targets: ["AIOEngine"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-collections",
      from: "1.2.1"
    ),
    .package(
      url: "https://github.com/apple/swift-async-algorithms",
      from: "1.0.4"
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
        .product(name: "OrderedCollections", package: "swift-collections"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
    .target(
      name: "AIOEngine",
      dependencies: [
        "Tools",
        "SystemLog",
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "Collections", package: "swift-collections"),
        .product(name: "DequeModule", package: "swift-collections"),
        .product(name: "OrderedCollections", package: "swift-collections"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
    .testTarget(
      name: "AIOTests",
      dependencies: ["AIOEngine"]
    ),
    .testTarget(
      name: "AudioVisualizationTests",
      dependencies: ["AIOEngine"]
    ),
    .testTarget(
      name: "ToolsTests",
      dependencies: ["Tools"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
    .target(
      name: "SystemLog",
      dependencies: [],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
  ]
)
