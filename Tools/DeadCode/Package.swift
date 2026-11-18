// swift-tools-version: 6.2
import PackageDescription

// The dead-code scan's own tool: which targets only tests reach, each platform's
// index reduced to its declaration sites, what of the sources only a Debug build
// compiles — which check-test-seams.sh reads through it too — and the
// per-platform Periphery reports combined into one. It builds wherever the scan
// runs, macOS and Linux.
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
        .target(
            name: "DeadCodeKit",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            swiftSettings: swiftSettings),
        .executableTarget(name: "dead-code", dependencies: ["DeadCodeKit"], swiftSettings: swiftSettings),
        .testTarget(name: "DeadCodeKitTests", dependencies: ["DeadCodeKit"], swiftSettings: swiftSettings),
    ]
)
