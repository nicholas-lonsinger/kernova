// swift-tools-version: 6.2
import CompilerPluginSupport
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
        // Static, and it has to stay static: Xcode gives every target that
        // links a *dynamic* package product a command copying that framework
        // into the shared `Products/<config>/Frameworks`, and the destination
        // carries no target name. Two command-line-tool targets linking one
        // dynamic product therefore write the same path and the build fails
        // with "Multiple commands produce" (Xcode 26.6; Xcode 27 emits no such
        // copy for a tool). Both `kernova` and the relaunch helper need this
        // code, so it links into each of them instead of being copied beside
        // them.
        //
        // Static also means every consumer must reach it statically. A dynamic
        // product that linked this one would carry its own copy, and a binary
        // loading both — a test bundle linking `KernovaCLICore` and this
        // together — would hold the registry's type metadata twice, so a cast
        // or a protocol conformance could resolve against the wrong one.
        // `KernovaCLICore` therefore has to stay the only library depending on
        // it, and anything else that needs it takes it directly.
        .library(name: "KernovaAppRegistry", type: .static, targets: ["KernovaAppRegistry"]),
        // Static for the same reasons as `KernovaAppRegistry` above, and read
        // that comment before changing this one: two command-line tools linking
        // one dynamic product collide in `Products/<config>/Frameworks`, and a
        // binary holding two copies of this module would hold two
        // `KernovaLogger.forwardingSink` variables — the guest agent installs
        // exactly one and every forwarded record would go to whichever copy the
        // logging call site resolved.
        .library(name: "KernovaLogging", type: .static, targets: ["KernovaLogging"]),
        .library(name: "KernovaCLICore", targets: ["KernovaCLICore"]),
        .library(name: "KernovaTestSupport", targets: ["KernovaTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
        // Linked by KernovaCLICore alone — neither the app nor the guest agent
        // gains a dependency.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // Backs the `#log` macro's implementation. The plugin it builds runs on
        // the build host and nothing it links reaches a shipped binary.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
    ],
    targets: [
        .target(
            name: "KernovaKit",
            dependencies: [
                "KernovaLogging",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // The one logging spelling: `KernovaLogger` plus the `#log` macro that
        // is the only way to emit through it. Its own target so the relaunch
        // helper can link it without linking everything else, and so it stays
        // clear of SwiftProtobuf — `KernovaLogLevel` is what a forwarded record
        // carries, and `VsockHostConnection` maps it to the proto enum.
        .target(
            name: "KernovaLogging",
            dependencies: ["KernovaLoggingMacros"],
            swiftSettings: sharedSwiftSettings
        ),
        .macro(
            name: "KernovaLoggingMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // Reading Launch Services' registry and waiting for it to let an app
        // go. Its own target rather than part of `KernovaKit` so the relaunch
        // helper can link it without linking everything else.
        .target(
            name: "KernovaAppRegistry",
            swiftSettings: sharedSwiftSettings
        ),
        // The `kernova` tool's whole vocabulary: parsing, rendering, exit
        // codes, and the client that speaks to the app. It lives in this
        // package so its tests ride `KernovaKitTests` — which is already in
        // Kernova.xctestplan — rather than needing a fourth test target.
        .target(
            name: "KernovaCLICore",
            dependencies: [
                "KernovaKit",
                "KernovaAppRegistry",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "KernovaTestSupport",
            dependencies: ["KernovaKit", "KernovaLogging"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "KernovaKitTests",
            dependencies: [
                "KernovaKit", "KernovaAppRegistry", "KernovaCLICore", "KernovaTestSupport",
                "KernovaLogging", "KernovaLoggingMacros",
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
    ]
)
