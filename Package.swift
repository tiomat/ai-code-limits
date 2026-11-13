// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AICodeLimitsMenuBar",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "AICodeLimitsMenuBar", targets: ["AICodeLimitsMenuBar"]),
  ],
  targets: [
    .executableTarget(name: "AICodeLimitsMenuBar"),
  ]
)