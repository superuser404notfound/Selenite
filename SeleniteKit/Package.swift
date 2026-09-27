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
        .library(name: "StreamKit", targets: ["StreamKit"]),
        .library(name: "MoonlightCore", targets: ["MoonlightCore"]),
        .library(name: "InputKit", targets: ["InputKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MbedCrypto",
            cSettings: mbedDefines + [.headerSearchPath("../../Vendor/mbedtls/library")]
        ),
        .target(name: "HostKit", dependencies: [
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
        ]),
        .target(name: "MoonlightCore"),
        .target(name: "InputKit", dependencies: ["MoonlightCore"]),
        .target(name: "MoonlightSlotA", dependencies: ["MoonlightCore", "MbedCrypto"], cSettings: slotSettings),
        .target(name: "MoonlightSlotB", dependencies: ["MoonlightCore", "MbedCrypto"], cSettings: slotSettings),
        .target(
            name: "OpusCodec",
            cSettings: [
                .define("OPUS_BUILD"), .define("USE_ALLOCA"),
                .define("HAVE_LRINTF", to: "1"), .define("HAVE_LRINT", to: "1"),
                .headerSearchPath("../../Vendor/opus/include"),
                .headerSearchPath("../../Vendor/opus/celt"),
                .headerSearchPath("../../Vendor/opus/silk"),
                .headerSearchPath("../../Vendor/opus/silk/float"),
                .headerSearchPath("../../Vendor/opus/src"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .target(
            name: "StreamKit",
            dependencies: ["HostKit", "MoonlightCore", "MoonlightSlotA", "MoonlightSlotB", "OpusCodec", "InputKit"],
            // UIWindow.avDisplayManager is an AVKit category: nothing links a symbol from it, so
            // without this the framework is never loaded and the call dies in doesNotRecognizeSelector.
            linkerSettings: [.linkedFramework("AVKit", .when(platforms: [.tvOS]))]
        ),
        .testTarget(name: "HostKitTests", dependencies: [
            "HostKit",
            .product(name: "X509", package: "swift-certificates"),
        ], resources: [.copy("Fixtures")]),
        .testTarget(name: "MoonlightCoreTests", dependencies: ["MbedCrypto", "MoonlightCore", "MoonlightSlotA", "MoonlightSlotB"]),
        .testTarget(name: "StreamKitTests", dependencies: ["StreamKit"]),
        .testTarget(name: "InputKitTests", dependencies: ["InputKit", "MoonlightCore"]),
    ]
)
