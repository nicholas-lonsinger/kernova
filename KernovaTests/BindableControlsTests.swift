import Testing
import AppKit
@testable import Kernova

@Suite("BindableControls Tests")
@MainActor
struct BindableControlsTests {
    @Observable
    @MainActor
    final class Source {
        var text: String = "initial"
        var flag: Bool = false
        var count: Int = 1
        var ratio: Double = 0.5
        var choice: Choice = .alpha
    }

    enum Choice: String, Equatable {
        case alpha, beta, gamma
    }

    private func drain() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: - BindableTextField

    @Test("BindableTextField initializes from observed.get()")
    func textInitial() {
        let source = Source()
        let field = BindableTextField(
            observed: Observed(
                get: { source.text },
                set: { source.text = $0 }
            )
        )
        #expect(field.stringValue == "initial")
    }

    @Test("BindableTextField updates stringValue when source changes (when unfocused)")
    func textTracksExternalChange() async {
        let source = Source()
        let field = BindableTextField(
            observed: Observed(
                get: { source.text },
                set: { source.text = $0 }
            )
        )

        source.text = "updated"
        await drain()
        #expect(field.stringValue == "updated")
    }

    // MARK: - BindableSwitch

    @Test("BindableSwitch initializes from observed.get()")
    func switchInitial() {
        let source = Source()
        source.flag = true
        let control = BindableSwitch(
            observed: Observed(
                get: { source.flag },
                set: { source.flag = $0 }
            )
        )
        #expect(control.state == .on)
    }

    @Test("BindableSwitch follows external bool changes")
    func switchTracksExternalChange() async {
        let source = Source()
        let control = BindableSwitch(
            observed: Observed(
                get: { source.flag },
                set: { source.flag = $0 }
            )
        )
        #expect(control.state == .off)

        source.flag = true
        await drain()
        #expect(control.state == .on)
    }

    // MARK: - BindableCheckbox

    @Test("BindableCheckbox initializes from observed.get()")
    func checkboxInitial() {
        let source = Source()
        let control = BindableCheckbox(
            title: "Enable",
            observed: Observed(
                get: { source.flag },
                set: { source.flag = $0 }
            )
        )
        #expect(control.state == .off)
        #expect(control.title == "Enable")
    }

    @Test("BindableCheckbox follows external bool changes")
    func checkboxTracksExternal() async {
        let source = Source()
        let control = BindableCheckbox(
            title: "Enable",
            observed: Observed(
                get: { source.flag },
                set: { source.flag = $0 }
            )
        )
        source.flag = true
        await drain()
        #expect(control.state == .on)
    }

    // MARK: - BindablePopUpButton

    @Test("BindablePopUpButton selects the matching option initially")
    func popupInitialSelection() {
        let source = Source()
        source.choice = .beta
        let popup = BindablePopUpButton(
            observed: Observed(
                get: { source.choice },
                set: { source.choice = $0 }
            ),
            options: [
                ("Alpha", Choice.alpha),
                ("Beta", Choice.beta),
                ("Gamma", Choice.gamma),
            ]
        )
        #expect(popup.indexOfSelectedItem == 1)
        #expect(popup.numberOfItems == 3)
    }

    @Test("BindablePopUpButton follows external value changes")
    func popupTracksExternal() async {
        let source = Source()
        let popup = BindablePopUpButton(
            observed: Observed(
                get: { source.choice },
                set: { source.choice = $0 }
            ),
            options: [
                ("Alpha", Choice.alpha),
                ("Beta", Choice.beta),
                ("Gamma", Choice.gamma),
            ]
        )
        #expect(popup.indexOfSelectedItem == 0)

        source.choice = .gamma
        await drain()
        #expect(popup.indexOfSelectedItem == 2)
    }

    // MARK: - BindableStepper

    @Test("BindableStepper initializes within range with current value")
    func stepperInitial() {
        let source = Source()
        source.count = 4
        let stepper = BindableStepper(
            observed: Observed(
                get: { source.count },
                set: { source.count = $0 }
            ),
            range: 1...8
        )
        // The internal NSStepper is one of the arranged subviews.
        let inner = stepper.arrangedSubviews.compactMap { $0 as? NSStepper }.first
        #expect(inner?.integerValue == 4)
    }

    // MARK: - BindableSlider

    @Test("BindableSlider initializes with current double")
    func sliderInitial() {
        let source = Source()
        source.ratio = 0.75
        let slider = BindableSlider(
            observed: Observed(
                get: { source.ratio },
                set: { source.ratio = $0 }
            ),
            range: 0.0...1.0
        )
        #expect(abs(slider.doubleValue - 0.75) < .ulpOfOne)
    }

    @Test("BindableSlider follows external value changes")
    func sliderTracksExternal() async {
        let source = Source()
        let slider = BindableSlider(
            observed: Observed(
                get: { source.ratio },
                set: { source.ratio = $0 }
            ),
            range: 0.0...1.0
        )
        source.ratio = 0.25
        await drain()
        #expect(abs(slider.doubleValue - 0.25) < .ulpOfOne)
    }
}
