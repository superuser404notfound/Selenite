import HostKit
import InputKit
import StreamKit
import Testing
@testable import AppCore

private let one = AppEntry(id: 1, title: "One", supportsHDR: false)
private let two = AppEntry(id: 2, title: "Two", supportsHDR: false)

@MainActor @Test func fullWizardWalksBothSidesThenLayout() {
    let wizard = SplitWizardModel()
    #expect(wizard.step == .host(.first))
    wizard.chooseHost("A")
    #expect(wizard.step == .game(.first))
    wizard.chooseGame(one)
    #expect(wizard.step == .host(.second))
    wizard.chooseHost("B")
    wizard.chooseGame(two)
    #expect(wizard.step == .layout)
    wizard.layout = .topBottom
    wizard.format = .sixteenByNine
    #expect(wizard.finish() == SplitPlan(first: SplitSideChoice(hostID: "A", app: one),
                                         second: SplitSideChoice(hostID: "B", app: two),
                                         layout: .topBottom, format: .sixteenByNine))
}

@MainActor @Test func theFirstSidesHostCannotBePickedForTheSecond() {
    let wizard = SplitWizardModel()
    wizard.chooseHost("A")
    wizard.chooseGame(one)
    #expect(!wizard.isHostSelectable("A"))
    #expect(wizard.isHostSelectable("B"))
    wizard.chooseHost("A")
    #expect(wizard.step == .host(.second))
}

@MainActor @Test func backStepsAndReportsLeavingAtTheStart() {
    let wizard = SplitWizardModel()
    wizard.chooseHost("A")
    #expect(wizard.back())
    #expect(wizard.step == .host(.first))
    #expect(!wizard.back())
}

@MainActor @Test func finishIsNilBeforeTheLastStep() {
    let wizard = SplitWizardModel()
    wizard.chooseHost("A")
    #expect(wizard.finish() == nil)
}

@MainActor @Test func startingFromAPlanPrefillsLayoutAndFormat() {
    let plan = SplitPlan(first: SplitSideChoice(hostID: "A", app: one), second: SplitSideChoice(hostID: "B", app: two),
                         layout: .topBottom, format: .sixteenByNine)
    let wizard = SplitWizardModel(startingFrom: plan)
    #expect(wizard.layout == .topBottom)
    #expect(wizard.format == .sixteenByNine)
    #expect(wizard.step == .host(.first))
}

@MainActor @Test func oneSideModeReplacesOnlyThatSide() {
    let plan = SplitPlan(first: SplitSideChoice(hostID: "A", app: one), second: SplitSideChoice(hostID: "B", app: two),
                         layout: .sideBySide, format: .fillHalf)
    let wizard = SplitWizardModel(replacing: .second, in: plan)
    #expect(wizard.step == .host(.second))
    #expect(!wizard.isHostSelectable("A"))
    wizard.chooseHost("C")
    wizard.chooseGame(one)
    var expected = plan
    expected.second = SplitSideChoice(hostID: "C", app: one)
    #expect(wizard.finish() == expected)
    #expect(wizard.back())
    #expect(wizard.step == .game(.second))
    #expect(wizard.back())
    #expect(!wizard.back())
}
