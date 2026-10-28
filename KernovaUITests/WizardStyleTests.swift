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

    @Test("A home matches whole components only")
    func homeMatchesWholeComponents() {
        #expect(
            wizardAbbreviateWithTilde("/Users/mel/Downloads/a.ipsw", homes: ["/Users/me"])
                == "/Users/mel/Downloads/a.ipsw")
    }

    @Test("The first home a path lies under wins")
    func firstMatchingHomeWins() {
        let container = "/Users/me/Library/Containers/app.kernova/Data/"
        #expect(
            wizardAbbreviateWithTilde(
                "/Users/me/Library/Containers/app.kernova/Data/Downloads/a.ipsw",
                homes: [container, "/Users/me"])
                == "~/Downloads/a.ipsw")
        #expect(
            wizardAbbreviateWithTilde("/Users/me/Desktop/a.ipsw", homes: [container, "/Users/me"])
                == "~/Desktop/a.ipsw")
    }
}
