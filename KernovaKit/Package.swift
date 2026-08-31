// swift-tools-version: 6.2
import PackageDescription

// Project targets take these from Config/Base.xcconfig; a package target never
// reads a project xcconfig, so the same gates are stated here.
let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "KernovaKit",
    platforms: [
        // Held to Config/Base.xcconfig's KERNOVA_AGENT_DEPLOYMENT_TARGET by
        // Tools/check-agent-deployment-floor.sh.
        .macOS(.v12)
    ],
    products: [
        .library(name: "KernovaKit", targets: ["KernovaKit"]),
        .library(name: "KernovaTestSupport", targets: ["KernovaTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0")
    ],
    targets: [
        .target(
            name: "KernovaKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "KernovaTestSupport",
            dependencies: ["KernovaKit"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "KernovaKitTests",
            dependencies: ["KernovaKit", "KernovaTestSupport"],
            swiftSettings: sharedSwiftSettings
        ),
    ]
)
