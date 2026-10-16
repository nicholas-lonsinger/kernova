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
        .library(name: "KernovaCore", targets: ["KernovaCore"])
    ],
    dependencies: [
        .package(path: "../KernovaKit")
    ],
    targets: [
        // Whatever the app does that needs neither AppKit nor Virtualization,
        // tested without the app as test host. Kernova.xcodeproj reaches its
        // `package` declarations through SWIFT_PACKAGE_NAME.
        .target(
            name: "KernovaCore",
            dependencies: [
                .product(name: "KernovaKit", package: "KernovaKit"),
                .product(name: "KernovaLogging", package: "KernovaKit"),
            ],
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
