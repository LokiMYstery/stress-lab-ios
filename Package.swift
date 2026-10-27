// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "StressLabCore", platforms: [.macOS(.v13)], products: [.library(name: "StressLabCore", targets: ["StressLabCore"])], targets: [.target(name: "StressLabCore", path: "Sources/Core"), .testTarget(name: "StressLabCoreTests", dependencies: ["StressLabCore"], path: "Tests/Core")])
