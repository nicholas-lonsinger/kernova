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
// and is declared only on macOS, so `swift build` and `swift test` on Linux or
// Windows build exactly the portable targets. SwiftPM evaluates a manifest for
// the machine it runs on, never for the destination a cross build names, so a
// build for Linux from a Mac sets KERNOVA_PORTABLE_ONLY and gets the manifest
// Linux evaluates.
#if os(macOS)
let declaresAppleTargets = Context.environment["KERNOVA_PORTABLE_ONLY"] == nil
#else
let declaresAppleTargets = false
#endif

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
        name: "KernovaLogging", type: .static, targets: ["KernovaLogging", "KernovaSynchronization"]),
    // The Linux guest agent, one static binary for the session and system
    // peers. Tools/build-linux-guest-agent.sh builds it for the app bundle.
    .executable(name: "kernova-agent", targets: ["KernovaLinuxAgent"]),
    // Measurements of Kernova's own code, run on the host and, built like the Linux agent, inside guests.
    .executable(name: "kernova-bench", targets: ["KernovaBench"]),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0")
]

var targets: [Target] = [
    // The one logging spelling: `KernovaLogger` and the `LogMessage` its
    // `log(_:_:)` takes. Its own target so the relaunch helper can link it
    // without linking everything else.
    .target(
        name: "KernovaLogging",
        dependencies: ["KernovaSynchronization"],
        swiftSettings: sharedSwiftSettings
    ),
    // The one way to standard output and standard error, for the targets that hold a command-line mode.
    .target(
        name: "KernovaConsole",
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
    // The C calls the portable targets make without importing an OS module:
    // the CRC32C instructions, the monotonic clock that counts sleep, the
    // vsock connect, whose `sockaddr_vm` neither Glibc nor Musl exports, and
    // the `openat2` and `renameat2` system calls, which musl does not wrap.
    .target(
        name: "CKernovaShims",
        linkerSettings: [.linkedLibrary("mincore", .when(platforms: [.windows]))]
    ),
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
        dependencies: [
            "KernovaDBus", "KernovaAgentRuntime", "KernovaAgentCore", "KernovaPlatformPOSIX", "KernovaWire",
            "KernovaDigest", "KernovaSynchronization", "CKernovaShims",
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // SHA-256, for the agents' payload hash.
    .target(
        name: "KernovaDigest",
        swiftSettings: sharedSwiftSettings
    ),
    // An ISO 9660 image writer with Rock Ridge, for the disks the host hands a guest. It imports nothing.
    .target(
        name: "KernovaISO9660",
        swiftSettings: sharedSwiftSettings
    ),
    // The scratch directory, wait backstop and interposed file system of the test targets that cannot
    // reach `KernovaTestSupport` (Tools/check-test-seams.sh), which re-exports it.
    .target(
        name: "KernovaPortableTestSupport",
        dependencies: ["KernovaFileTree"],
        swiftSettings: sharedSwiftSettings
    ),
    // The Linux agent's display version. Tools/build-linux-guest-agent.sh
    // writes the label the C file includes; without it the label reads
    // "development".
    .target(name: "CKernovaAgentVersion"),
    // `kernova-agent`. Declared on every platform, like
    // `KernovaPlatformLinux`, with its body compiled only for Linux.
    .executableTarget(
        name: "KernovaLinuxAgent",
        dependencies: [
            "KernovaAgentInstall", "KernovaPlatformLinux", "KernovaAgentRuntime", "KernovaAgentCore", "KernovaDBus",
            "KernovaDigest", "KernovaLogging", "KernovaSynchronization", "KernovaWire", "KernovaConsole",
            "CKernovaAgentVersion",
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // `kernova-bench`.
    .executableTarget(
        name: "KernovaBench",
        dependencies: [
            "KernovaWire", "KernovaContainer", "KernovaContainerPipeline", "KernovaSynchronization",
            "KernovaTreeTransfer", "KernovaFileTree", "KernovaDigest",
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // The non-blocking `ByteStream` over a socket. Declared on every platform,
    // like `KernovaPlatformLinux`, with its sources compiled only for Darwin
    // and Linux.
    .target(
        name: "KernovaPlatformPOSIX",
        dependencies: ["KernovaAgentRuntime", "KernovaSynchronization"],
        swiftSettings: sharedSwiftSettings
    ),
    // Trees walked and changed through descriptors, one name at a time: the
    // file-system protocol, the cursor, and the Darwin and Linux calls. A leaf
    // beside the agent runtime, so the app's kit links it without the runtime;
    // the protocol and the cursor compile everywhere, the calls into the OS
    // only for Darwin and Linux.
    .target(
        name: "KernovaFileTree",
        dependencies: ["CKernovaShims"],
        swiftSettings: sharedSwiftSettings
    ),
    // The guest-agent protocol's sans-I/O state machines: streams, credit,
    // Hello, liveness and close, and every feature's machines per role.
    .target(
        name: "KernovaAgentCore",
        dependencies: [
            "KernovaWire", "KernovaSynchronization", .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // An item pull's answer: the transfer container's records, encoded from
    // entries and decoded incrementally into `TreeEvent`s.
    .target(
        name: "KernovaContainer",
        dependencies: ["KernovaWire", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
        swiftSettings: sharedSwiftSettings
    ),
    // The container codec around the sans-I/O encoder and decoder: LZ4 tried and decompressed on worker lanes,
    // records kept in stream order, and the per-transfer compression choice.
    .target(
        name: "KernovaContainerPipeline",
        dependencies: ["KernovaContainer", "KernovaSynchronization"],
        swiftSettings: sharedSwiftSettings
    ),
    // An item pull's landing: the writer that creates a tree from `TreeEvent`s through descriptors alone,
    // never resolving a path, and the receiver that feeds it a container. Its own target, so neither the
    // codec nor the file-tree layer takes on the other.
    .target(
        name: "KernovaTreeTransfer",
        dependencies: [
            "KernovaContainer", "KernovaContainerPipeline", "KernovaFileTree", "KernovaWire", "KernovaLogging",
            "KernovaSynchronization", .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // The item adapters a shell registers: the sink landing pulls through `KernovaTreeTransfer` and the source
    // serving offers through it, over the runtime's `ItemSink` and `ItemSource`.
    .target(
        name: "KernovaItemTransfer",
        dependencies: [
            "KernovaAgentRuntime", "KernovaAgentCore", "KernovaTreeTransfer", "KernovaContainer",
            "KernovaContainerPipeline", "KernovaFileTree", "KernovaWire", "KernovaSynchronization", "KernovaLogging",
            "KernovaTransferProgress",
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // The deterministic, fault-injecting harness that runs `KernovaAgentCore`
    // endpoints against each other on virtual time.
    .target(
        name: "KernovaAgentSimulation",
        dependencies: [
            "KernovaAgentCore", "KernovaContainer", "KernovaFileTree", "KernovaWire", "KernovaPortableTestSupport",
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // Drives the core: one serial queue and one `ByteStream` per connection,
    // the platform clock, the dial schedule, and the adapter registry.
    .target(
        name: "KernovaAgentRuntime",
        dependencies: [
            "KernovaAgentCore", "KernovaWire", "KernovaLogging", "KernovaSynchronization", "CKernovaShims",
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // An agent's install and in-band update, on every OS with an agent: the root and its slots, the switch,
    // confirm and rollback, and the install plan with what carries it out. The service manager and a payload
    // format's lander are each OS's, reached through the protocols it declares. Its sources compile only for
    // Darwin and Linux, but for the plan's data, which compiles everywhere.
    .target(
        name: "KernovaAgentInstall",
        dependencies: [
            "KernovaAgentRuntime", "KernovaAgentCore", "KernovaWire", "KernovaDigest", "KernovaLogging",
            "KernovaSynchronization", "KernovaContainer", "KernovaTreeTransfer", "KernovaFileTree",
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // The host's side: one hub per VM over the runtime's host connections,
    // and the transport admission it accepts through. Portable, though only
    // the Mac runs a host, so its tests ride the runtime's harness.
    .target(
        name: "KernovaAgentHost",
        dependencies: [
            "KernovaAgentRuntime", "KernovaAgentCore", "KernovaWire", "KernovaLogging", "KernovaSynchronization",
            "KernovaDigest",
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // One transfer's progress as every surface renders it: the operation a feature owner measures a gesture with,
    // the units its pulls' landings feed, and the reporter that ranks a side's operations into one readout.
    .target(
        name: "KernovaTransferProgress",
        dependencies: ["KernovaAgentCore", "KernovaLogging", "KernovaSynchronization", "CKernovaShims"],
        swiftSettings: sharedSwiftSettings
    ),
    // Like `KernovaPortableTests` below, it cannot reach `KernovaTestSupport`.
    .testTarget(
        name: "KernovaWireTests",
        dependencies: [
            "KernovaWire", "KernovaPortableTestSupport", .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // Like `KernovaWireTests`, it cannot reach `KernovaTestSupport`.
    .testTarget(
        name: "KernovaContainerTests",
        dependencies: [
            "KernovaContainer", "KernovaContainerPipeline", "KernovaWire", "KernovaSynchronization",
            "KernovaPortableTestSupport",
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
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
        dependencies: ["KernovaPlatformLinux", "KernovaDBus", "KernovaAgentCore", "KernovaAgentRuntime"],
        swiftSettings: sharedSwiftSettings
    ),
    .testTarget(
        name: "KernovaLinuxAgentTests",
        dependencies: [
            "KernovaLinuxAgent", "KernovaAgentInstall", "KernovaAgentCore", "KernovaSynchronization", "KernovaWire",
            "KernovaPortableTestSupport",
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // Like `KernovaWireTests`, it cannot reach `KernovaTestSupport`. Its suites, like the target they test,
    // compile only for Darwin and Linux. The golden payload beside them is read from the source tree.
    .testTarget(
        name: "KernovaAgentInstallTests",
        dependencies: [
            "KernovaAgentInstall", "KernovaAgentCore", "KernovaAgentRuntime", "KernovaAgentSimulation",
            "KernovaDigest", "KernovaLogging", "KernovaWire", "KernovaPortableTestSupport", "KernovaContainer",
            "KernovaFileTree", "KernovaSynchronization",
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        exclude: ["Golden"],
        swiftSettings: sharedSwiftSettings
    ),
    // Like `KernovaWireTests`, it cannot reach `KernovaTestSupport`. The
    // transcripts beside it are read from the source tree.
    .testTarget(
        name: "KernovaAgentCoreTests",
        dependencies: [
            "KernovaAgentCore", "KernovaAgentSimulation", "KernovaContainer", "KernovaWire", "KernovaDigest",
            "KernovaPortableTestSupport",
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        exclude: ["Transcripts"],
        swiftSettings: sharedSwiftSettings
    ),
    // Like `KernovaWireTests`, it cannot reach `KernovaTestSupport`. Its
    // socket suites, like the target they test, compile only for Darwin and
    // Linux.
    .testTarget(
        name: "KernovaAgentRuntimeTests",
        dependencies: [
            "KernovaAgentRuntime", "KernovaAgentCore", "KernovaAgentSimulation", "KernovaWire", "KernovaLogging",
            "KernovaSynchronization", "KernovaPlatformPOSIX", "KernovaAgentHost", "KernovaItemTransfer",
            "KernovaFileTree", "KernovaTransferProgress", "KernovaPortableTestSupport",
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // The hostile-container corpus, run against this OS's writer. Like `KernovaWireTests`, it cannot reach
    // `KernovaTestSupport`.
    .testTarget(
        name: "KernovaTreeTransferTests",
        dependencies: [
            "KernovaTreeTransfer", "KernovaContainer", "KernovaFileTree", "KernovaWire", "KernovaLogging",
            "KernovaSynchronization", "KernovaDigest", "KernovaPortableTestSupport", "KernovaAgentSimulation",
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // Like `KernovaWireTests`, it cannot reach `KernovaTestSupport`.
    .testTarget(
        name: "KernovaItemTransferTests",
        dependencies: [
            "KernovaItemTransfer", "KernovaAgentRuntime", "KernovaAgentCore", "KernovaAgentSimulation",
            "KernovaTreeTransfer", "KernovaContainer", "KernovaContainerPipeline", "KernovaFileTree", "KernovaWire",
            "KernovaSynchronization", "KernovaLogging", "KernovaTransferProgress", "KernovaPortableTestSupport",
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ],
        swiftSettings: sharedSwiftSettings
    ),
    // Like `KernovaWireTests`, it cannot reach `KernovaTestSupport`.
    .testTarget(
        name: "KernovaFileTreeTests",
        dependencies: ["KernovaFileTree", "KernovaPortableTestSupport"],
        swiftSettings: sharedSwiftSettings
    ),
    // The portable targets' tests. It cannot reach `KernovaTestSupport`, which
    // is Apple-only, so its suites carry no `.caseScoped` and mint no scratch
    // (Tools/check-test-seams.sh).
    .testTarget(
        name: "KernovaPortableTests",
        dependencies: [
            "KernovaLogging", "KernovaSynchronization", "KernovaDigest", "KernovaISO9660", "KernovaPortableTestSupport",
        ],
        swiftSettings: sharedSwiftSettings
    ),
]

if declaresAppleTargets {
    products += [
        .library(name: "KernovaKit", targets: ["KernovaKit", "KernovaTransferProgress"]),
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
        // The app's agent hub, the protocol types and stream it is driven
        // with, and the item adapters it serves and lands through, for KernovaCore.
        .library(
            name: "KernovaAgentHost",
            targets: [
                "KernovaAgentHost", "KernovaAgentRuntime", "KernovaAgentCore", "KernovaWire", "KernovaPlatformPOSIX",
                "KernovaItemTransfer", "KernovaFileTree", "KernovaClipboardItems", "KernovaTransferProgress",
            ]),
        // The writer the app makes the Linux agent's disk with, for KernovaCore.
        .library(name: "KernovaISO9660", targets: ["KernovaISO9660"]),
        // The macOS guest agent's peer, install and update, and the core it runs on. Static for the reasons
        // `KernovaLogging`'s comment gives.
        .library(
            name: "KernovaPlatformDarwin", type: .static,
            targets: [
                "KernovaPlatformDarwin", "KernovaAgentInstall", "KernovaAgentRuntime", "KernovaAgentCore",
                "KernovaWire", "KernovaPlatformPOSIX", "KernovaDigest", "KernovaClipboardItems",
                "KernovaTransferProgress",
            ]),
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
                "KernovaFileTree",
                "KernovaWire",
                "KernovaTransferProgress",
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // What the app and the `kernova` tool share and no guest agent links:
        // the command wire, the library's queries, config-file decoding.
        .target(
            name: "KernovaCommandModel",
            dependencies: ["KernovaKit", "KernovaLogging", "KernovaSynchronization"],
            swiftSettings: sharedSwiftSettings
        ),
        // The clipboard over the agent connection's items, the same at the host and the macOS guest agent: a
        // pasteboard's offers, the far side's offers published lazily, and the pulls that land them.
        .target(
            name: "KernovaClipboardItems",
            dependencies: [
                "KernovaKit", "KernovaAgentCore", "KernovaAgentRuntime", "KernovaWire", "KernovaLogging",
                "KernovaSynchronization", "KernovaTransferProgress",
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // The AppKit UI the app and the macOS guest agent share.
        .target(
            name: "KernovaAppKitShared",
            dependencies: ["KernovaKit", "KernovaLogging", "KernovaTransferProgress"],
            swiftSettings: sharedSwiftSettings
        ),
        // What the macOS guest agent calls into macOS for: the vsock dial, its identity and session state, and
        // launchd, which runs and updates it.
        .target(
            name: "KernovaPlatformDarwin",
            dependencies: [
                "KernovaAgentInstall", "KernovaAgentRuntime", "KernovaAgentCore", "KernovaPlatformPOSIX", "KernovaWire",
                "KernovaDigest", "KernovaLogging", "KernovaSynchronization", "KernovaItemTransfer", "KernovaFileTree",
                "KernovaConsole", "KernovaKit", "KernovaTransferProgress",
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "KernovaPlatformDarwinTests",
            dependencies: [
                "KernovaPlatformDarwin", "KernovaAgentInstall", "KernovaAgentCore", "KernovaAgentRuntime",
                "KernovaWire", "KernovaSynchronization", "KernovaTestSupport",
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
        // Kernova.xctestplan — rather than needing a test target of their own.
        .target(
            name: "KernovaCLICore",
            dependencies: [
                "KernovaKit",
                "KernovaCommandModel",
                "KernovaAppRegistry",
                "KernovaSynchronization",
                "KernovaConsole",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "KernovaTestSupport",
            dependencies: [
                "KernovaKit", "KernovaLogging", "KernovaSynchronization", "KernovaTransferProgress",
                "KernovaPortableTestSupport",
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "KernovaKitTests",
            dependencies: [
                "KernovaKit", "KernovaCommandModel", "KernovaAppKitShared", "KernovaAppRegistry",
                "KernovaCLICore", "KernovaTestSupport", "KernovaLogging", "KernovaSynchronization",
                "KernovaFileTree", "KernovaWire", "KernovaClipboardItems", "KernovaAgentCore", "KernovaAgentRuntime",
                "KernovaConsole", "KernovaTransferProgress",
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
}

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
