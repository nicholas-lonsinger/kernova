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
        .library(name: "KernovaVirtualization", targets: ["KernovaVirtualization"]),
        .library(name: "KernovaUI", targets: ["KernovaUI"]),
        .library(name: "KernovaCoreTestSupport", targets: ["KernovaCoreTestSupport"]),
        .library(
            name: "KernovaVirtualizationTestSupport", targets: ["KernovaVirtualizationTestSupport"]),
    ],
    dependencies: [
        .package(path: "../KernovaKit"),
        // For the tests, which build messages with its `with`. Any 1.x: SwiftPM
        // resolves one version for the graph, and KernovaKit's requirement is
        // the one that sets its floor.
        .package(url: "https://github.com/apple/swift-protobuf.git", "1.0.0"..<"2.0.0"),
    ],
    targets: [
        .target(
            name: "KernovaCore",
            dependencies: [
                .product(name: "KernovaKit", package: "KernovaKit"),
                .product(name: "KernovaAgentHost", package: "KernovaKit"),
                .product(name: "KernovaCommandModel", package: "KernovaKit"),
                .product(name: "KernovaLogging", package: "KernovaKit"),
                .product(name: "KernovaISO9660", package: "KernovaKit"),
            ],
            resources: [
                .copy("Resources/LinuxAgentDisk"),
                .copy("Resources/LinuxImageCatalog.json"),
                .copy("Resources/RestoreImageCatalog.json"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // The Virtualization adapters. An unhosted test runner lacks the
        // virtualization entitlement, so a test that validates a configuration
        // or builds a VZVirtualMachine runs in KernovaUITests, hosted by
        // KernovaTestHost.
        .target(
            name: "KernovaVirtualization",
            dependencies: [
                "KernovaCore",
                .product(name: "KernovaKit", package: "KernovaKit"),
                .product(name: "KernovaAgentHost", package: "KernovaKit"),
                .product(name: "KernovaCommandModel", package: "KernovaKit"),
                .product(name: "KernovaLogging", package: "KernovaKit"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // The AppKit layer. Its tests need a running NSApplication, which no
        // package test target can host, so they are the KernovaUITests bundle
        // in Kernova.xcodeproj, hosted by KernovaTestHost.
        .target(
            name: "KernovaUI",
            dependencies: [
                "KernovaCore",
                "KernovaVirtualization",
                .product(name: "KernovaKit", package: "KernovaKit"),
                .product(name: "KernovaAgentHost", package: "KernovaKit"),
                .product(name: "KernovaCommandModel", package: "KernovaKit"),
                .product(name: "KernovaAppKitShared", package: "KernovaKit"),
                .product(name: "KernovaAppRegistry", package: "KernovaKit"),
                .product(name: "KernovaLogging", package: "KernovaKit"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // The fakes and fixtures every bundle testing the core shares.
        // KernovaUITests links the product beside KernovaUI, into the one image
        // that holds them (Tools/check-package-reference.sh).
        .target(
            name: "KernovaCoreTestSupport",
            dependencies: [
                "KernovaCore",
                .product(name: "KernovaKit", package: "KernovaKit"),
                .product(name: "KernovaAgentHost", package: "KernovaKit"),
                .product(name: "KernovaCommandModel", package: "KernovaKit"),
                .product(name: "KernovaLogging", package: "KernovaKit"),
                .product(name: "KernovaTestSupport", package: "KernovaKit"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // The fakes and fixtures both lanes testing the engine share:
        // KernovaVirtualizationTests, and the tests in KernovaUITests that
        // need the entitlement.
        .target(
            name: "KernovaVirtualizationTestSupport",
            dependencies: [
                "KernovaCore",
                "KernovaCoreTestSupport",
                "KernovaVirtualization",
                .product(name: "KernovaCommandModel", package: "KernovaKit"),
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
                .product(name: "KernovaAgentHost", package: "KernovaKit"),
                .product(name: "KernovaCommandModel", package: "KernovaKit"),
                .product(name: "KernovaLogging", package: "KernovaKit"),
                .product(name: "KernovaTestSupport", package: "KernovaKit"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "KernovaVirtualizationTests",
            dependencies: [
                "KernovaCore",
                "KernovaCoreTestSupport",
                "KernovaVirtualization",
                "KernovaVirtualizationTestSupport",
                .product(name: "KernovaKit", package: "KernovaKit"),
                .product(name: "KernovaCommandModel", package: "KernovaKit"),
                .product(name: "KernovaLogging", package: "KernovaKit"),
                .product(name: "KernovaTestSupport", package: "KernovaKit"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
    ]
)
