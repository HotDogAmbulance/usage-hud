// swift-tools-version: 5.7
import PackageDescription
let package = Package(
    name: "UsageHUD", platforms: [.macOS(.v12)],
    products: [.executable(name: "usagehud", targets: ["UsageHUD"]),
               .executable(name: "usagehud-tests", targets: ["UsageHUDTests"])],
    targets: [.target(name: "UsageHUDCore"),
              .executableTarget(name: "UsageHUD", dependencies: ["UsageHUDCore"]),
              .executableTarget(name: "UsageHUDTests", dependencies: ["UsageHUDCore"], path: "Tests/UsageHUDCoreTests")])
