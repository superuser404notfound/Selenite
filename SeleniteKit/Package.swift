// swift-tools-version:6.2
import PackageDescription

// Every target that includes PSA headers must share these, the PSA structs change layout with threading.
let mbedDefines: [CSetting] = [
    .define("MBEDTLS_THREADING_C"),
    .define("MBEDTLS_THREADING_PTHREAD"),
    .headerSearchPath("../../Vendor/mbedtls/include"),
]

let package = Package(
    name: "SeleniteKit",
    platforms: [.tvOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HostKit", targets: ["HostKit"]),
    ],
    targets: [
        .target(
            name: "MbedCrypto",
            cSettings: mbedDefines + [.headerSearchPath("../../Vendor/mbedtls/library")]
        ),
        .target(name: "HostKit"),
        .testTarget(name: "HostKitTests", dependencies: ["HostKit"]),
        .testTarget(name: "MoonlightCoreTests", dependencies: ["MbedCrypto"]),
    ]
)
