import AppIntents
import Foundation

struct FindAttachedUSBAccessoriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Attached USB Accessories"
    static let description: IntentDescription? = IntentDescription(
        "Answers the USB accessories a virtual machine’s guest holds. USB accessory passthrough needs macOS 27 or later.",
        categoryName: "Virtual Machines",
        resultValueName: "USB Accessories")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Find the USB accessories attached to \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[USBAccessoryEntity]> {
        .result(value: try await gateway.usbAccessories(attachedTo: vm.id))
    }
}

struct FindAvailableUSBAccessoriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Available USB Accessories"
    static let description: IntentDescription? = IntentDescription(
        "Answers the USB accessories you’ve assigned to Kernova in macOS’s Virtual Machine Accessories menu extra that no virtual machine holds. USB accessory passthrough needs macOS 27 or later.",
        categoryName: "Virtual Machines",
        resultValueName: "USB Accessories")

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Find the USB accessories available to attach")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[USBAccessoryEntity]> {
        .result(value: try await gateway.availableUSBAccessories())
    }
}

struct AttachUSBAccessoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Attach USB Accessory"
    static let description: IntentDescription? = IntentDescription(
        "Passes a USB accessory through to a running virtual machine’s guest, and remembers it there: the virtual machine takes it back automatically whenever both are available, unless the accessory reports nothing Kernova can recognize it by. An accessory can be attached once you’ve assigned it to Kernova in macOS’s Virtual Machine Accessories menu extra, while no virtual machine holds it. USB accessory passthrough needs macOS 27 or later.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "USB Accessory")
    var accessory: USBAccessoryEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Attach \(\.$accessory) to \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await gateway.attachUSBAccessory(vm.id, accessory: accessory.id, named: accessory.name)
        return .result()
    }
}

struct DetachUSBAccessoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Detach USB Accessory"
    static let description: IntentDescription? = IntentDescription(
        "Takes a USB accessory back off a running virtual machine’s guest, and forgets it there: the virtual machine no longer takes it back automatically. USB accessory passthrough needs macOS 27 or later.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "USB Accessory")
    var accessory: USBAccessoryEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Detach \(\.$accessory) from \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await gateway.detachUSBAccessory(vm.id, accessory: accessory.id, named: accessory.name)
        return .result()
    }
}

struct FindRememberedUSBAccessoriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Remembered USB Accessories"
    static let description: IntentDescription? = IntentDescription(
        "Answers the USB accessories a virtual machine takes back automatically, plugged in or not. Attach USB Accessory remembers one; Detach USB Accessory and Forget USB Accessory forget it. USB accessory passthrough needs macOS 27 or later.",
        categoryName: "Virtual Machines",
        resultValueName: "Remembered USB Accessories")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Find the remembered USB accessories of \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[RememberedUSBAccessoryEntity]> {
        .result(value: try await gateway.rememberedUSBAccessories(ofVM: vm.id))
    }
}

struct ForgetUSBAccessoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Forget USB Accessory"
    static let description: IntentDescription? = IntentDescription(
        "Stops a virtual machine taking a remembered USB accessory back automatically. Attaching it again remembers it again. USB accessory passthrough needs macOS 27 or later.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Remembered USB Accessory")
    var accessory: RememberedUSBAccessoryEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Forget \(\.$accessory) for \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await gateway.forgetUSBAccessory(vm.id, accessory: accessory.id)
        return .result()
    }
}
