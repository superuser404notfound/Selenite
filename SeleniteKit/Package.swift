// swift-tools-version:6.2
import PackageDescription

// Every target that includes PSA headers must share these, the PSA structs change layout with threading.
let mbedDefines: [CSetting] = [
    .define("MBEDTLS_THREADING_C"),
    .define("MBEDTLS_THREADING_PTHREAD"),
    .headerSearchPath("../../Vendor/mbedtls/include"),
]

let slotSettings: [CSetting] = mbedDefines + [
    .define("NDEBUG"), .define("HAS_SOCKLEN_T"), .define("__APPLE_USE_RFC_3542"),
    .define("HAS_FCNTL", to: "1"), .define("HAS_IOCTL", to: "1"), .define("HAS_POLL", to: "1"),
    .define("HAS_GETADDRINFO", to: "1"), .define("HAS_GETNAMEINFO", to: "1"),
    .define("HAS_INET_PTON", to: "1"), .define("HAS_INET_NTOP", to: "1"), .define("HAS_MSGHDR_FLAGS", to: "1"),
    .define("USE_MBEDTLS"),
    .headerSearchPath("../../Vendor/moonlight-common-c/enet/include"),
    .headerSearchPath("../../Vendor/moonlight-common-c/nanors"),
    .headerSearchPath("../../Vendor/moonlight-common-c/nanors/deps"),
    .headerSearchPath("../../Vendor/moonlight-common-c/nanors/deps/obl"),
    // Upstream moonlight-common-c/enet emit -Wshorten-64-to-32 under SwiftPM's default warning
    // set; the vendored sources are out of scope to fix (see CLAUDE.md), so silence warnings for
    // these two targets only, keeping `swift test` output pristine.
    .unsafeFlags(["-w"]),
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
        .target(name: "MoonlightCore"),
        .target(name: "MoonlightSlotA", dependencies: ["MoonlightCore", "MbedCrypto"], cSettings: slotSettings),
        .target(name: "MoonlightSlotB", dependencies: ["MoonlightCore", "MbedCrypto"], cSettings: slotSettings),
        .testTarget(name: "HostKitTests", dependencies: ["HostKit"]),
        .testTarget(name: "MoonlightCoreTests", dependencies: ["MbedCrypto", "MoonlightCore", "MoonlightSlotA", "MoonlightSlotB"]),
    ]
)
