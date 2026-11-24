import AppIntents
import Foundation

struct StartVMIntent: ConsentingIntent {
    static let title: LocalizedStringResource = "Start Virtual Machine"
    // A machine that still owes guest setup does not boot here: `start`
    // dispatches the install or image download and returns, so this action
    // reports before the setup it began has finished, and says so.
    static let description: IntentDescription? = IntentDescription(
        "Starts a virtual machine, or begins the guest setup one still owes — which carries on after this reports. Confirm Before Starting asks before starting it beside an active virtual machine with the same machine ID, where Kernova’s Settings allow starting one anyway.",
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
        "Stops a virtual machine. Give Up After makes the action wait for the guest to power off, and fail, leaving the virtual machine as it is, if it hasn’t within that time; without it, a Normal or Anyway stop finishes once the guest has been asked to shut down. Confirm Before Stopping asks before a method that loses anything in the guest that isn’t saved to disk.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Stop Method", default: .graceful)
    var method: VMStopMethod

    @Parameter(title: "Give Up After", defaultUnit: .seconds, supportsNegativeNumbers: false)
    var giveUpAfter: Measurement<UnitDuration>?

    @Parameter(title: "Confirm Before Stopping", default: true)
    var confirmsFirst: Bool

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Stop \(\.$vm)") {
            \.$method
            \.$giveUpAfter
            \.$confirmsFirst
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runWithConsent { consent in
            try await gateway.stop(
                vm.id, disposition: method.disposition, consent: consent,
                givingUpAfter: giveUpAfter?.converted(to: .seconds).value)
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
        "Lets a paused guest run again, or reads a suspended session back. Confirm Before Resuming asks before resuming it beside an active virtual machine with the same machine ID, where Kernova’s Settings allow starting one anyway.",
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
        "Takes the guest down and starts it again once it has powered off. Give Up After limits how long the action waits for the power-off: a guest that hasn’t powered off by then is not started again. Confirm Before Restarting asks before a method that loses anything in the guest that isn’t saved to disk, and before starting it again beside an active virtual machine with the same machine ID, where Kernova’s Settings allow starting one anyway.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Restart Method", default: .graceful)
    var method: VMStopMethod

    @Parameter(title: "Give Up After", defaultUnit: .seconds, supportsNegativeNumbers: false)
    var giveUpAfter: Measurement<UnitDuration>?

    @Parameter(title: "Confirm Before Restarting", default: true)
    var confirmsFirst: Bool

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Restart \(\.$vm)") {
            \.$method
            \.$giveUpAfter
            \.$confirmsFirst
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runWithConsent { consent in
            try await gateway.restart(
                vm.id, disposition: method.disposition, consent: consent,
                givingUpAfter: giveUpAfter?.converted(to: .seconds).value)
        }
        return .result()
    }
}

struct WaitForVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Wait for Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
        "Waits until a virtual machine is running, is stopped, or has its guest agent connected and up to date, or until Kernova has seen its guest use an IP address, and returns the virtual machine as it is then. Fails if the virtual machine fails or leaves the library first and, waiting for an IP address, when Kernova can see none for it, as for one that is bridged or not running. With Give Up After, fails once that time passes; without it, waits with no limit.",
        categoryName: "Virtual Machines",
        resultValueName: "Virtual Machine")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Condition", default: .running)
    var condition: VMWaitCondition

    @Parameter(title: "Give Up After", defaultUnit: .seconds, supportsNegativeNumbers: false)
    var giveUpAfter: Measurement<UnitDuration>?

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Wait until \(\.$vm) \(\.$condition)") {
            \.$giveUpAfter
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<VMEntity> {
        .result(
            value: try await gateway.wait(
                vm.id, until: condition.condition,
                givingUpAfter: giveUpAfter?.converted(to: .seconds).value))
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
