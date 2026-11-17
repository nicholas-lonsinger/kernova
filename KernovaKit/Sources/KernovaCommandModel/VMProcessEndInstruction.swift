import Foundation

/// How a person ends a virtual machine's process that Kernova is waiting on
/// and cannot end itself — what a pending Force Stop tells whoever looks at
/// the VM or asks it for something.
///
/// The app composes it, since only the app holds the bundle path and its own
/// name, and every surface — a `kernova` refusal included — shows it as sent.
public struct VMProcessEndInstruction: Codable, Sendable, Hashable {
    /// What is happening and that the command below ends it, ending in a colon.
    public let explanation: String
    /// The Terminal command that ends this VM's process and no other.
    public let command: String

    /// The instruction for the VM whose bundle is at `bundlePath`, in a copy
    /// of the app named `appName`.
    public init(appName: String, bundlePath: String) {
        explanation =
            "\(appName) is waiting for this virtual machine\u{2019}s process to end and can\u{2019}t end it "
            + "itself. If it doesn\u{2019}t end, run this command in Terminal:"
        command = Self.command(endingProcessOfBundleAt: bundlePath)
    }

    /// The explanation, then the command on a line of its own — the form a
    /// refusal's message carries it in.
    public var text: String { explanation + "\n  " + command }

    /// The command that ends the Virtualization process holding files inside
    /// the bundle at `bundlePath` open.
    ///
    /// A VM's process holds files in its own bundle open and Kernova holds
    /// none of them, so the bundle names that one process
    /// (docs/research/2026-11-17-sandboxed-app-cannot-end-vm-process.md). The
    /// path is one single-quoted shell word, so no character in it is read by
    /// the shell.
    public static func command(endingProcessOfBundleAt bundlePath: String) -> String {
        "kill -9 $(lsof -t -c com.apple.Virtualization -a +D \(shellWord(bundlePath)))"
    }

    /// `text` as one POSIX shell word: single-quoted, with each single quote
    /// in it closed, escaped and reopened.
    private static func shellWord(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
