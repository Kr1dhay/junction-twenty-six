// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "EdgeCareCore", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "EdgeCareCore", targets: ["EdgeCareCore"]), .library(name: "EdgeCareUI", targets: ["EdgeCareUI"])],
    targets: [.target(name: "EdgeCareCore", resources: [.process("Resources")]),
              .target(name: "EdgeCareUI", dependencies: ["EdgeCareCore"]),
              .testTarget(name: "EdgeCareCoreTests", dependencies: ["EdgeCareCore"])])
