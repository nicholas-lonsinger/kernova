// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KernovaProtocol",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "KernovaProtocol", targets: ["KernovaProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.37.0"),
    ],
    targets: [
        .target(
            name: "KernovaProtocol",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "KernovaProtocolTests",
            dependencies: ["KernovaProtocol"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
