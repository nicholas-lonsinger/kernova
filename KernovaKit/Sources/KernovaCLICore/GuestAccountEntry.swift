import Foundation

/// How `kernova start` is given the password for the account a VM owes its
/// guest: standard input, and nothing else.
///
/// The tool asks no question of its own. `readpassphrase(3)` turns terminal
/// echo off with `tcsetattr`, which the App Sandbox denies this tool — observed
/// 2026-09-16 as `Sandbox: kernova deny(1) file-ioctl path:/dev/tty
/// ioctl-command:(_IO "t" 22)` while a prompt ran — and the call reads with
/// echo left on rather than failing, so a prompt here would print the password
/// to the terminal. No entitlement lifts a tty ioctl, so the prompt is not
/// offered at all; the password arrives through `--admin-password-stdin`, or
/// the user answers Kernova's own sheet.
enum GuestAccountEntry {
    /// Standard input, read to EOF, with one trailing newline removed.
    ///
    /// Read whole rather than a line at a time: a password may contain
    /// anything, and only the newline a shell adds at the very end is not part
    /// of it.
    static func passwordFromStandardInput() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
