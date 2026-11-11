import Testing

@testable import KernovaUI

@Suite("WizardStyle Tests", .caseScoped)
struct WizardStyleTests {
    @Test(
        "A path under a home abbreviates to ~/ and the rest, however the home is spelled",
        arguments: ["/Users/me", "/Users/me/"])
    func abbreviatesUnderAHome(home: String) {
        #expect(
            wizardAbbreviateWithTilde("/Users/me/Downloads/RestoreImage.ipsw", homes: [home])
                == "~/Downloads/RestoreImage.ipsw")
        #expect(wizardAbbreviateWithTilde("/Users/me", homes: [home]) == "~")
    }
}
