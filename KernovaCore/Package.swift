// swift-tools-version: 6.2
import PackageDescription

// Project targets take these from Config/Base.xcconfig; a package target never
// reads a project xcconfig, so the same gates are stated here.
//
// MemberImportVisibility: KernovaKit imports AppKit, and without the feature
// AppKit's extension members on Foundation types resolve in any file that
// imports KernovaKit. With it, a member resolves only from a module the file
// imports itself, which Tools/check-core-imports.sh holds to its allowlist.
let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "KernovaCore",
    platforms: [
        // The app's MACOSX_DEPLOYMENT_TARGET (Config/Base.xcconfig).
        .macOS(.v26)
    ],
    products: [
        .library(name: "KernovaCore", targets: ["KernovaCore"]),
        .library(name: "KernovaUI", targets: ["KernovaUI"]),
    ],
    dependencies: [
        .package(path: "../KernovaKit"),
        // The version KernovaKit takes; the tests build messages with its `with`.
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    ],
    targets: [
        .target(
            name: "KernovaCore",
            dependencies: [
                .product(name: "KernovaKit", package: "KernovaKit"),
                .product(name: "KernovaLogging", package: "KernovaKit"),
            ],
            resources: [
                .copy("Resources/LinuxImageCatalog.json"),
                .copy("Resources/RestoreImageCatalog.json"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // The AppKit layer. Its tests need a running NSApplication, which no
        // package test target can host, so they are the KernovaUITests bundle
        // in Kernova.xcodeproj, hosted by KernovaTestHost.
        .target(
            name: "KernovaUI",
            dependencies: ["KernovaCore"],
            swiftSettings: sharedSwiftSettings
        ),
        // The fakes and fixtures KernovaCoreTests and the app-hosted
        // KernovaTests share. No product: the hosted bundle compiles this folder
        // into itself, since linking it would put a second KernovaCore beside
        // the app's.
        .target(
            name: "KernovaCoreTestSupport",
            dependencies: [
                "KernovaCore",
                .product(name: "KernovaKit", package: "KernovaKit"),
                .product(name: "KernovaLogging", package: "KernovaKit"),
                .product(name: "KernovaTestSupport", package: "KernovaKit"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "KernovaCoreTests",
            dependencies: [
                "KernovaCore",
                "KernovaCoreTestSupport",
                .product(name: "KernovaKit", package: "KernovaKit"),
                .product(name: "KernovaLogging", package: "KernovaKit"),
                .product(name: "KernovaTestSupport", package: "KernovaKit"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
    ]
)
