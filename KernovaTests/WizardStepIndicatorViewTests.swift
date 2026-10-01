import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("WizardStepIndicatorView Tests", .caseScoped)
@MainActor
struct WizardStepIndicatorViewTests {
    private func spokenSteps(_ indicator: WizardStepIndicatorView) -> [String] {
        indicator.unignoredAccessibilityElements.compactMap { element in
            guard element.accessibilityRole() == .staticText else { return nil }
            return element.accessibilityValue() as? String
        }
    }

    @Test("Each step is one text element, and the current one says so as the step moves")
    func currentStepIsSpokenOnItsText() throws {
        let steps = Array(VMCreationStep.allCases.prefix(3))
        try #require(steps.count == 3)
        let indicator = WizardStepIndicatorView()
        indicator.steps = steps
        indicator.currentStep = steps[0]

        #expect(indicator.unignoredAccessibilityElements.allSatisfy { $0.accessibilityRole() == .staticText })
        #expect(
            spokenSteps(indicator)
                == [steps[0].title + ", current step", steps[1].title, steps[2].title])

        indicator.currentStep = steps[1]

        #expect(
            spokenSteps(indicator)
                == [steps[0].title, steps[1].title + ", current step", steps[2].title])
    }
}
