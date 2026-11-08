import AppIntents
import Foundation
import KernovaKit

struct StartVMIntent: ConsentingIntent {
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

    @Parameter(title: "Confirm Before Starting", default: true)
    var confirmsFirst: Bool

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$vm)") {
            \.$recovery
            \.$confirmsFirst
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runWithConsent { consent in
            try await gateway.start(vm.id, recovery: recovery, consent: consent)
        }
        return .result()
    }
}

struct StopVMIntent: ConsentingIntent {
    static let title: LocalizedStringResource = "Stop Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
        "Stops a virtual machine. Confirm Before Stopping asks before a method that loses anything in the guest that isn’t saved to disk.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Stop Method", default: .graceful)
    var method: VMStopMethod

    @Parameter(title: "Confirm Before Stopping", default: true)
    var confirmsFirst: Bool

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Stop \(\.$vm)") {
            \.$method
            \.$confirmsFirst
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runWithConsent { consent in
            try await gateway.stop(vm.id, disposition: method.disposition, consent: consent)
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
        try await gateway.pause(vm.id)
        return .result()
    }
}

struct ResumeVMIntent: ConsentingIntent {
    static let title: LocalizedStringResource = "Resume Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
        "Lets a paused guest run again, or reads a suspended session back.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Confirm Before Resuming", default: true)
    var confirmsFirst: Bool

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Resume \(\.$vm)") {
            \.$confirmsFirst
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runWithConsent { consent in
            try await gateway.resume(vm.id, consent: consent)
        }
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
        try await gateway.suspend(vm.id)
        return .result()
    }
}

struct RestartVMIntent: ConsentingIntent {
    static let title: LocalizedStringResource = "Restart Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
        "Takes the guest down and starts it again once it has powered off. Confirm Before Restarting asks before a method that loses anything in the guest that isn’t saved to disk.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Restart Method", default: .graceful)
    var method: VMStopMethod

    @Parameter(title: "Confirm Before Restarting", default: true)
    var confirmsFirst: Bool

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Restart \(\.$vm)") {
            \.$method
            \.$confirmsFirst
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runWithConsent { consent in
            try await gateway.restart(vm.id, disposition: method.disposition, consent: consent)
        }
        return .result()
    }
}

/// Brings a VM in front of the user: its display when it has one, else its
/// place in the library.
///
/// The one intent that foregrounds Kernova, because putting the VM in front of
/// the user is the whole of what it does — and the `OpenIntent` Spotlight runs
/// when somebody presses Return on an indexed VM, which is why it reveals
/// rather than refusing every VM that is not running.
struct OpenVMIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
        "Shows a virtual machine — its display when it has one, else its place in the library.",
        categoryName: "Virtual Machines")

    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Virtual Machine")
    var target: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await gateway.reveal(target.id)
        return .result()
    }
}
