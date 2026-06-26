// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KernovaKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "KernovaKit", targets: ["KernovaKit"])
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
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "KernovaKitTests",
            dependencies: ["KernovaKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
