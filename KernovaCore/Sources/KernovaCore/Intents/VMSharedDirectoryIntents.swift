import AppIntents
import Foundation

struct FindSharedDirectoriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Shared Directories"
    static let description: IntentDescription? = IntentDescription(
        "Answers the folders a virtual machine shares with its guest, in the order it shares them.",
        categoryName: "Virtual Machines",
        resultValueName: "Shared Directories")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Find the shared directories of \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SharedDirectoryEntity]> {
        .result(value: try await gateway.sharedDirectories(ofVM: vm.id))
    }
}

struct AddSharedDirectoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Shared Directory"
    static let description: IntentDescription? = IntentDescription(
        "Shares the folder at a path with a virtual machine’s guest and returns the shared directory. When Kernova can’t already read the folder, it comes to the front and asks for it in an open panel, and shares the folder chosen there. A folder the virtual machine already shares is left as it is. With Read Only on, the guest can read the folder but not write to it.",
        categoryName: "Virtual Machines",
        resultValueName: "Shared Directory")

    // Runs in the background, and comes to the front only to put up the open
    // panel (`ActivationRequester`).
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    // Apple documents a file an action receives as readable for the span of
    // the action (`IntentFile.fileURL`), and nothing about a bookmark made from
    // it outliving the action; a share is reopened at every boot, through the
    // bookmark an open panel's pick yields (Accessing files from the macOS App
    // Sandbox).
    @Parameter(title: "Path")
    var path: String

    @Parameter(title: "Read Only", default: false)
    var readOnly: Bool

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Share \(\.$path) with \(\.$vm)") {
            \.$readOnly
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SharedDirectoryEntity> {
        let folder = URL(fileURLWithPath: path).lastPathComponent
        return .result(
            value: try await gateway.addSharedDirectory(vm.id, path: path, readOnly: readOnly) {
                guard systemContext.currentMode != .foreground else { return }
                try await continueInForeground(
                    "Kernova needs your permission to read \u{201C}\(folder)\u{201D}.", alwaysConfirm: false)
            })
    }
}

struct RemoveSharedDirectoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove Shared Directory"
    static let description: IntentDescription? = IntentDescription(
        "Stops sharing a folder with a virtual machine’s guest. The folder itself is left alone.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Shared Directory")
    var directory: SharedDirectoryEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Remove \(\.$directory) from \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await gateway.removeSharedDirectory(vm.id, directory: directory.id)
        return .result()
    }
}
