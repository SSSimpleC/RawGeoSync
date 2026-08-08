// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "MetadataInfrastructure",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(
      name: "MetadataInfrastructure",
      targets: ["MetadataInfrastructure"]
    )
  ],
  targets: [
    .target(
      name: "MetadataInfrastructure"
    ),
    .testTarget(
      name: "MetadataInfrastructureTests",
      dependencies: ["MetadataInfrastructure"]
    ),
  ]
)
