// swift-tools-version: 6.2
import PackageDescription

// Project targets take these from Config/Base.xcconfig; a package target never
// reads a project xcconfig, so the same gates are stated here.
let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
]

// The portable targets build wherever Swift does — macOS, Linux, Windows — and
// are the code that builds off Apple platforms. Everything else is Apple-only
// and is declared only where the manifest is evaluated on macOS, so
// `swift build` and `swift test` on Linux or Windows build exactly the portable
// targets. A cross build from a Mac evaluates the manifest for macOS, so it
// names its targets (the Makefile's `PORTABLE_TARGETS`).
var products: [Product] = [
    // Static, and it has to stay static: Xcode gives every target that links a
    // *dynamic* package product a command copying that framework into the
    // shared `Products/<config>/Frameworks`, and the destination carries no
    // target name. Two command-line-tool targets linking one dynamic product
    // therefore write the same path and the build fails with "Multiple
    // commands produce" (Xcode 26.6; Xcode 27 emits no such copy for a tool).
    //
    // Static also means every consumer must reach it statically: a binary
    // holding two copies of this module would hold two process sinks
    // (`KernovaLogger.processSink`) — the guest agent bootstraps exactly one,
    // and a record logged through the other copy would not be forwarded.
    //
    // `KernovaSynchronization` ships inside this product, so every image
    // linking `KernovaLogging` can import it without a project edit.
    .library(
        name: "KernovaLogging", type: .static, targets: ["KernovaLogging", "KernovaSynchronization"])
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0")
]

var targets: [Target] = [
    // The one logging spelling: `KernovaLogger` and the `LogMessage` its
    // `log(_:_:)` takes. Its own target so the relaunch helper can link it
    // without linking everything else, and so it stays clear of
    // SwiftProtobuf — `KernovaLogLevel` is what a forwarded record carries,
    // and `VsockHostConnection` maps it to the proto enum.
    .target(
        name: "KernovaLogging",
        dependencies: ["KernovaSynchronization"],
        swiftSettings: sharedSwiftSettings
    ),
    // A leaf, so `KernovaLogging` can hold its process sink in a `Locked`.
    .target(
        name: "KernovaSynchronization",
        swiftSettings: sharedSwiftSettings
    ),
    // The guest-agent protocol's wire layer.
    .target(
        name: "KernovaWire",
        dependencies: [
            "CKernovaShims",
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        // The generated Swift beside it is checked in (Tools/check-generated-protos.sh).
        exclude: ["Proto/kernova_v2.proto"],
        swiftSettings: sharedSwiftSettings
    ),
    // The C intrinsics Swift cannot spell: the CRC32C instructions.
    .target(name: "CKernovaShims"),
    // The D-Bus protocol with no I/O: types, marshalling, messages, SASL
    // EXTERNAL, and a connection driven by the bytes a transport moves.
    .target(
        name: "KernovaDBus",
        swiftSettings: sharedSwiftSettings
    ),
    // What the Linux guest agent calls into Linux for. It is declared on every
    // platform, its sources compiled only for Linux, because a cross build
    // from a Mac evaluates this manifest for macOS.
    .target(
        name: "KernovaPlatformLinux",
        dependencies: ["KernovaDBus"],
        swiftSettings: sharedSwiftSettings
    ),
    // Like `KernovaPortableTests` below, it cannot reach `KernovaTestSupport`.
    .testTarget(
        name: "KernovaWireTests",
        dependencies: ["KernovaWire", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
        swiftSettings: sharedSwiftSettings
    ),
    .testTarget(
        name: "KernovaDBusTests",
        dependencies: ["KernovaDBus"],
        swiftSettings: sharedSwiftSettings
    ),
    // Against a private `dbus-daemon` each test starts; compiled, like the
    // target it tests, only for Linux.
    .testTarget(
        name: "KernovaPlatformLinuxTests",
        dependencies: ["KernovaPlatformLinux", "KernovaDBus"],
        swiftSettings: sharedSwiftSettings
    ),
    // The portable targets' tests. It cannot reach `KernovaTestSupport`, which
    // is Apple-only, so its suites carry no `.caseScoped` and mint no scratch
    // (Tools/check-test-seams.sh).
    .testTarget(
        name: "KernovaPortableTests",
        dependencies: ["KernovaLogging", "KernovaSynchronization"],
        swiftSettings: sharedSwiftSettings
    ),
]

#if os(macOS)
products += [
    .library(name: "KernovaKit", targets: ["KernovaKit"]),
    .library(name: "KernovaCommandModel", targets: ["KernovaCommandModel"]),
    .library(name: "KernovaAppKitShared", targets: ["KernovaAppKitShared"]),
    // Static for the reasons `KernovaLogging`'s comment gives, so read it
    // before changing this one.
    //
    // A dynamic product that linked this one would carry its own copy, and a
    // binary loading both — a test bundle linking `KernovaCLICore` and this
    // together — would hold the registry's type metadata twice, so a cast or a
    // protocol conformance could resolve against the wrong one.
    // `KernovaCLICore` therefore has to stay the only library depending on it,
    // and anything else that needs it takes it directly.
    .library(name: "KernovaAppRegistry", type: .static, targets: ["KernovaAppRegistry"]),
    .library(name: "KernovaCLICore", targets: ["KernovaCLICore"]),
    .library(name: "KernovaTestSupport", targets: ["KernovaTestSupport"]),
]

dependencies += [
    // Linked by KernovaCLICore alone — neither the app nor the guest agent
    // gains a dependency.
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
]

targets += [
    .target(
        name: "KernovaKit",
        dependencies: [
            "KernovaLogging",
            "KernovaSynchronization",
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        // The generated Swift beside it is checked in (Tools/check-generated-protos.sh).
        exclude: ["Proto/kernova.proto"],
        swiftSettings: sharedSwiftSettings,
        // `import AppleArchive` does not autolink the C library its
        // `__AAHeader…` functions live in
        // (docs/research/2026-10-23-applearchive-extract-semantics.md,
        // finding 3).
        linkerSettings: [.linkedLibrary("AppleArchive")]
    ),
    // What the app and the `kernova` tool share and no guest agent links:
    // the command wire, the library's queries, config-file decoding.
    .target(
        name: "KernovaCommandModel",
        dependencies: ["KernovaKit", "KernovaLogging", "KernovaSynchronization"],
        swiftSettings: sharedSwiftSettings
    ),
    // The AppKit UI the app and the macOS guest agent share.
    .target(
        name: "KernovaAppKitShared",
        dependencies: ["KernovaKit", "KernovaLogging"],
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
    // Kernova.xctestplan — rather than needing a test target of their own.
    .target(
        name: "KernovaCLICore",
        dependencies: [
            "KernovaKit",
            "KernovaCommandModel",
            "KernovaAppRegistry",
            "KernovaSynchronization",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        swiftSettings: sharedSwiftSettings
    ),
    .target(
        name: "KernovaTestSupport",
        dependencies: ["KernovaKit", "KernovaLogging", "KernovaSynchronization"],
        swiftSettings: sharedSwiftSettings
    ),
    .testTarget(
        name: "KernovaKitTests",
        dependencies: [
            "KernovaKit", "KernovaCommandModel", "KernovaAppKitShared", "KernovaAppRegistry",
            "KernovaCLICore", "KernovaTestSupport", "KernovaLogging", "KernovaSynchronization",
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // Every exit test, and nothing else: a test target runs in a process
    // of its own (Tools/check-exit-tests.sh).
    .testTarget(
        name: "KernovaKitExitTests",
        dependencies: ["KernovaLogging", "KernovaTestSupport"],
        swiftSettings: sharedSwiftSettings
    ),
]
#endif

let package = Package(
    name: "KernovaKit",
    platforms: [
        // Held to Config/Base.xcconfig's KERNOVA_AGENT_DEPLOYMENT_TARGET by
        // Tools/check-agent-deployment-floor.sh.
        .macOS(.v12)
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
