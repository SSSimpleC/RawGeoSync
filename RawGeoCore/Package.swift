// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "RawGeoCore",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "RawGeoCore", targets: ["RawGeoCore"])
  ],
  targets: [
    .target(name: "RawGeoCore"),
    .testTarget(name: "RawGeoCoreTests", dependencies: ["RawGeoCore"]),
  ]
)
