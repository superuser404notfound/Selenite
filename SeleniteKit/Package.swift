// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SeleniteKit",
    platforms: [.tvOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HostKit", targets: ["HostKit"]),
    ],
    targets: [
        .target(name: "HostKit"),
        .testTarget(name: "HostKitTests", dependencies: ["HostKit"]),
    ]
)
