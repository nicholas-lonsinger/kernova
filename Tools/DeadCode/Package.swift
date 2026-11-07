// swift-tools-version: 6.2
import PackageDescription

// The dead-code scan's own tool: which targets only tests reach, each platform's
// index reduced to its declaration sites, and the per-platform Periphery reports
// combined into one. It builds wherever the scan runs, macOS and Linux.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "DeadCode",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "DeadCodeKit", swiftSettings: swiftSettings),
        .executableTarget(name: "dead-code", dependencies: ["DeadCodeKit"], swiftSettings: swiftSettings),
        .testTarget(name: "DeadCodeKitTests", dependencies: ["DeadCodeKit"], swiftSettings: swiftSettings),
    ]
)
