import KernovaCommandModel

/// The question asked before a virtual machine comes up beside an active one
/// with the same machine ID: the confirmation a bring-up raises, and the same
/// words naming no virtual machine, which Settings shows.
package enum DuplicateMachineIDQuestion {
    /// Apple's claim the question puts in front of the user, quoted from the
    /// `machineIdentifier` discussion in `VZMacPlatformConfiguration.h`.
    package static let vendorClaim =
        "Apple: \u{201C}Running two virtual machines concurrently with the same identifier "
        + "results in undefined behavior in the guest operating system.\u{201D}"

    /// The question for the bring-up `verb` performs, naming `names.vm` and
    /// the active `names.other` it shares its machine ID with; with `names`
    /// nil, the question as it reads for no virtual machine in particular.
    package static func prompt(
        verb: VMVerb?, names: (vm: String, other: String, otherHeldByAnotherCopy: Bool)?
    ) -> ConfirmationPrompt {
        let control = VMCommandCore.bringUpTitle(verb)
        return ConfirmationPrompt(
            kind: .startBesideSharedMachineIdentity,
            title: names.map { "\(control) \u{201C}\($0.vm)\u{201D} with a Duplicate Machine ID?" }
                ?? "\(control) with a Duplicate Machine ID?",
            message: CommandErrorDTO.sharedMachineIdentitySentence(
                names.map { ($0.vm, $0.other) },
                otherHeldByAnotherCopy: names?.otherHeldByAnotherCopy ?? false)
                + " " + vendorClaim,
            confirmTitle: control,
            dismissTitle: "Cancel")
    }
}
