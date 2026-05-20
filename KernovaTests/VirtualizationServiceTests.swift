import Testing
import Foundation
import Virtualization
@testable import Kernova

@Suite("VirtualizationService Tests")
@MainActor
struct VirtualizationServiceTests {
    private let service = VirtualizationService()

    private func makeInstance(status: VMStatus = .stopped) -> VMInstance {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: status)
    }

    // MARK: - Start Guards

    @Test("start throws when VM is already running")
    func startThrowsWhenRunning() async {
        let instance = makeInstance(status: .running)

        await #expect(throws: VirtualizationError.self) {
            try await service.start(instance)
        }
    }

    @Test("start throws when VM is paused")
    func startThrowsWhenPaused() async {
        let instance = makeInstance(status: .paused)

        await #expect(throws: VirtualizationError.self) {
            try await service.start(instance)
        }
    }

    @Test("start throws when VM is starting")
    func startThrowsWhenStarting() async {
        let instance = makeInstance(status: .starting)

        await #expect(throws: VirtualizationError.self) {
            try await service.start(instance)
        }
    }

    // MARK: - Stop Guards

    @Test("stop throws when VM is stopped")
    func stopThrowsWhenStopped() {
        let instance = makeInstance(status: .stopped)

        #expect(throws: VirtualizationError.self) {
            try service.stop(instance)
        }
    }

    @Test("stop throws when VM is starting")
    func stopThrowsWhenStarting() {
        let instance = makeInstance(status: .starting)

        #expect(throws: VirtualizationError.self) {
            try service.stop(instance)
        }
    }

    // MARK: - Pause Guards

    @Test("pause throws when VM is stopped")
    func pauseThrowsWhenStopped() async {
        let instance = makeInstance(status: .stopped)

        await #expect(throws: VirtualizationError.self) {
            try await service.pause(instance)
        }
    }

    @Test("pause throws when VM is paused")
    func pauseThrowsWhenAlreadyPaused() async {
        let instance = makeInstance(status: .paused)

        await #expect(throws: VirtualizationError.self) {
            try await service.pause(instance)
        }
    }

    // MARK: - Resume Guards

    @Test("resume throws when VM is stopped")
    func resumeThrowsWhenStopped() async {
        let instance = makeInstance(status: .stopped)

        await #expect(throws: VirtualizationError.self) {
            try await service.resume(instance)
        }
    }

    @Test("resume throws when VM is running")
    func resumeThrowsWhenRunning() async {
        let instance = makeInstance(status: .running)

        await #expect(throws: VirtualizationError.self) {
            try await service.resume(instance)
        }
    }

    // MARK: - Save Guards

    @Test("save throws when VM is stopped")
    func saveThrowsWhenStopped() async {
        let instance = makeInstance(status: .stopped)

        await #expect(throws: VirtualizationError.self) {
            try await service.save(instance)
        }
    }

    // MARK: - ForceStop Guards

    @Test("forceStop throws when no virtual machine exists and not cold-paused")
    func forceStopThrowsWhenNoVM() async {
        let instance = makeInstance(status: .running)
        // No virtualMachine assigned, and not cold-paused (status is .running)

        await #expect(throws: VirtualizationError.self) {
            try await service.forceStop(instance)
        }
    }

    // MARK: - Transient Start Error Classification

    @Test("VM limit exceeded error is transient")
    func vmLimitExceededIsTransient() {
        let error = NSError(domain: VZError.errorDomain, code: VZError.Code.virtualMachineLimitExceeded.rawValue)
        #expect(VirtualizationService.isTransientStartError(error))
    }

    @Test("operation cancelled error is transient")
    func operationCancelledIsTransient() {
        let error = NSError(domain: VZError.errorDomain, code: VZError.Code.operationCancelled.rawValue)
        #expect(VirtualizationService.isTransientStartError(error))
    }

    @Test("invalid VM configuration error is permanent")
    func invalidConfigurationIsPermanent() {
        let error = NSError(domain: VZError.errorDomain, code: VZError.Code.invalidVirtualMachineConfiguration.rawValue)
        #expect(!VirtualizationService.isTransientStartError(error))
    }

    @Test("internal VZ error is permanent")
    func internalVZErrorIsPermanent() {
        let error = NSError(domain: VZError.errorDomain, code: VZError.Code.internalError.rawValue)
        #expect(!VirtualizationService.isTransientStartError(error))
    }

    @Test("configuration builder error is permanent")
    func configBuilderErrorIsPermanent() {
        let error = ConfigurationBuilderError.missingKernelPath
        #expect(!VirtualizationService.isTransientStartError(error))
    }

    @Test("unknown domain error is permanent")
    func unknownDomainIsPermanent() {
        let error = NSError(domain: "SomeOtherDomain", code: 42)
        #expect(!VirtualizationService.isTransientStartError(error))
    }

    @Test("start sets error status for permanent config error")
    func startSetsErrorForPermanentConfigError() async throws {
        let instance = makeInstance(status: .stopped)

        // start() fails at buildConfiguration (no real disk image) with a
        // ConfigurationBuilderError — a permanent error. The transient path
        // is covered by the isTransientStartError unit tests above.
        await #expect(throws: (any Error).self) {
            try await service.start(instance)
        }
        #expect(instance.status == .error)
        #expect(instance.errorMessage != nil)
    }

    // MARK: - Post-install Hand-off

    /// Verifies the post-install hand-off branch in `start(_:)`.
    ///
    /// When `instance.virtualMachine` is already attached (the post-install
    /// hand-off from `MacOSInstallService`), `start(_:)` must skip the
    /// `buildConfiguration` rebuild and call `vm.start()` directly on the
    /// existing instance. Rebuilding races VZ's file lock on auxiliary
    /// storage and reproduces the "Failed to lock auxiliary storage" bug
    /// this commit closes.
    ///
    /// We don't need a real VZ guest to verify the branch selection —
    /// only that the rebuild *path* isn't taken. A linux-kernel config with
    /// no `kernelPath` is the cleanest probe: when `buildConfiguration`
    /// runs, it throws `ConfigurationBuilderError.missingKernelPath`
    /// deterministically. With the hand-off in place, the function reaches
    /// `vm.start()` instead and fails (or succeeds) with a different
    /// error class.
    @Test("start uses attached virtualMachine and skips buildConfiguration")
    func startUsesAttachedVMAndSkipsBuild() async throws {
        // Linux-kernel boot mode with no `kernelPath` → buildConfiguration
        // would throw `.missingKernelPath` if invoked.
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .linuxKernel
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: .stopped)

        // Attach a real VZVirtualMachine. The kernel URL points at a
        // non-existent path on purpose: `VZVirtualMachine.init` does not
        // validate, so construction succeeds; `vm.start()` will fail with
        // a VZError, which is exactly the signal we want — anything other
        // than `ConfigurationBuilderError`.
        let vzConfig = VZVirtualMachineConfiguration()
        vzConfig.cpuCount = 1
        vzConfig.memorySize = 1024 * 1024 * 1024
        vzConfig.platform = VZGenericPlatformConfiguration()
        vzConfig.bootLoader = VZLinuxBootLoader(
            kernelURL: URL(fileURLWithPath: "/tmp/kernova-tests-nonexistent-kernel")
        )
        instance.attachVirtualMachine(from: vzConfig)
        #expect(instance.virtualMachine != nil)

        do {
            try await service.start(instance)
            // start() succeeded against a stub kernel — vanishingly
            // unlikely but not a test failure: the hand-off branch was
            // exercised, that's the point.
        } catch let error as ConfigurationBuilderError {
            Issue.record(
                "buildConfiguration was invoked despite an attached VM: \(error)"
            )
        } catch {
            // Any non-ConfigurationBuilderError is acceptable — proves the
            // hand-off branch ran and `vm.start()` was reached.
        }

        // start()'s failure path clears the VM via tearDownSession; status
        // ends up either .error (permanent VZ error) or .stopped (transient).
        #expect(instance.virtualMachine == nil)
    }
}
