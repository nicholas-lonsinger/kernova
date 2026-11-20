// swift-tools-version: 6.2
import PackageDescription

// Tools that build wherever they run, macOS and Linux. Only `DeadCodeSources` parses Swift, so only
// `dead-code-sources` links swift-syntax.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "DeadCode",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Its major version names the Swift release it parses: the one `.swift-version` pins.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0")
    ],
    targets: [
        .target(name: "DeadCodeKit", swiftSettings: swiftSettings),
        .target(
            name: "DeadCodeSources",
            dependencies: [
                "DeadCodeKit",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            swiftSettings: swiftSettings),
        .executableTarget(name: "dead-code", dependencies: ["DeadCodeKit"], swiftSettings: swiftSettings),
        .executableTarget(
            name: "dead-code-sources", dependencies: ["DeadCodeKit", "DeadCodeSources"], swiftSettings: swiftSettings),
        .testTarget(
            name: "DeadCodeTests", dependencies: ["DeadCodeKit", "DeadCodeSources"], swiftSettings: swiftSettings),
    ]
)
