import AppIntents
import Foundation
import KernovaKit

struct StartVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Virtual Machine"
    // A machine that still owes guest setup does not boot here: `start`
    // dispatches the install or image download and returns, so this action
    // reports before the setup it began has finished, and says so.
    static let description: IntentDescription? = IntentDescription(
        "Starts a virtual machine, or begins the guest setup one still owes — which carries on after this reports.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Start in Recovery Mode", default: false)
    var recovery: Bool

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$vm)") {
            \.$recovery
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await gateway.start(vm.id, recovery: recovery)
        return .result()
    }
}

struct StopVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
        "Stops a virtual machine, asking before anything that discards unsaved guest state.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Stop Method", default: .shutDown)
    var method: VMStopMethod

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Stop \(\.$vm)") {
            \.$method
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await runWithConsent { confirmed in
            try await gateway.stop(vm.id, disposition: method.disposition, confirmed: confirmed)
        }
        return .result()
    }
}

struct PauseVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
        "Suspends the guest's execution in place, leaving it in memory.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Pause \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await gateway.pause(vm.id)
        return .result()
    }
}

struct ResumeVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
        "Lets a paused guest run again.", categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Resume \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await gateway.resume(vm.id)
        return .result()
    }
}

struct SuspendVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Suspend Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
        "Saves the running guest to disk so a later start picks the session up where it stopped.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Suspend \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await gateway.suspend(vm.id)
        return .result()
    }
}

struct RestartVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Restart Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
        "Shuts the guest down and starts it again once it has powered off.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Restart \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await gateway.restart(vm.id)
        return .result()
    }
}

/// Brings a VM's display to the front.
///
/// The one intent that foregrounds Kernova, because putting a display in front
/// of the user is the whole of what it does.
struct OpenVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
        "Brings a virtual machine's display to the front.", categoryName: "Virtual Machines")

    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await gateway.open(vm.id)
        return .result()
    }
}
