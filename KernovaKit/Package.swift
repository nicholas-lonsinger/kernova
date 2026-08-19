// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KernovaKit",
    platforms: [
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
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
            ]
        ),
        .target(
            name: "KernovaTestSupport",
            dependencies: ["KernovaKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
            ]
        ),
        .testTarget(
            name: "KernovaKitTests",
            dependencies: ["KernovaKit", "KernovaTestSupport"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
            ]
        ),
    ]
)
