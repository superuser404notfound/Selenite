import Foundation
import HostKit
import InputKit
import StreamKit
import Testing
@testable import AppCore

private func defaults() -> UserDefaults {
    let name = "split-store-\(UUID().uuidString)"
    return UserDefaults(suiteName: name)!
}

private let plan = SplitPlan(
    first: SplitSideChoice(hostID: "A", app: AppEntry(id: 1, title: "One", supportsHDR: false)),
    second: SplitSideChoice(hostID: "B", app: AppEntry(id: 2, title: "Two", supportsHDR: false)),
    layout: .topBottom, format: .sixteenByNine)

@MainActor @Test func planSurvivesARestart() {
    let d = defaults()
    SplitStore(defaults: d).save(plan)
    #expect(SplitStore(defaults: d).plan == plan)
}

@MainActor @Test func removingAHostInThePlanClearsIt() {
    let d = defaults()
    let store = SplitStore(defaults: d)
    store.save(plan)
    store.removeHost(id: "C")
    #expect(store.plan == plan)
    store.removeHost(id: "B")
    #expect(store.plan == nil)
    #expect(SplitStore(defaults: d).plan == nil)
}

@MainActor @Test func volumesDefaultToFullAndAreClamped() {
    let d = defaults()
    let store = SplitStore(defaults: d)
    #expect(store.volume(for: .first) == 1)
    store.setVolume(0.4, for: .second)
    store.setVolume(3, for: .first)
    let reloaded = SplitStore(defaults: d)
    #expect(abs(reloaded.volume(for: .second) - 0.4) < 0.001)
    #expect(reloaded.volume(for: .first) == 1)
}

@MainActor @Test func aPlanThatNoLongerParsesIsDropped() {
    let d = defaults()
    d.set(Data("nope".utf8), forKey: SplitStore.planKey)
    #expect(SplitStore(defaults: d).plan == nil)
}

@Test func planSubscriptAndInvolves() {
    var p = plan
    #expect(p[.second].hostID == "B")
    p[.second] = SplitSideChoice(hostID: "C", app: p[.second].app)
    #expect(p.second.hostID == "C")
    #expect(p.involves(hostID: "A"))
    #expect(!p.involves(hostID: "B"))
}
