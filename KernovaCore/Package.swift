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
        .package(path: "../KernovaKit")
    ],
    targets: [
        .target(
            name: "KernovaCore",
            dependencies: [
                .product(name: "KernovaKit", package: "KernovaKit"),
                .product(name: "KernovaLogging", package: "KernovaKit"),
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
        .testTarget(
            name: "KernovaCoreTests",
            dependencies: [
                "KernovaCore",
                .product(name: "KernovaTestSupport", package: "KernovaKit"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
    ]
)
