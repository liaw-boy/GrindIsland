import AppKit
import XCTest
@testable import GrindIsland

final class IslandPresenceTests: XCTestCase {
    private func active(autoHide: Bool = true, playing: Bool = false, agent: Bool = false, expanded: Bool = false,
                        idle: Bool = false, forced: Bool = false) -> Bool {
        IslandPresence.shouldBeActive(autoHideWhenIdle: autoHide, playing: playing, agentAttention: agent,
                                      forceExpanded: expanded, forcedIdle: idle, forcedActive: forced)
    }

    func testHiddenWhenNothingGoingOn() { XCTAssertFalse(active()) }
    func testShownWhilePlaying() { XCTAssertTrue(active(playing: true)) }
    func testShownWhenAgentNeedsAttention() { XCTAssertTrue(active(agent: true)) }
    func testAlwaysShownWhenAutoHideOff() { XCTAssertTrue(active(autoHide: false)) }
    func testExpandedFlagKeepsItShown() { XCTAssertTrue(active(expanded: true)) }
    func testForcedIdleHidesEvenWhilePlaying() { XCTAssertFalse(active(playing: true, idle: true)) }
    func testForcedActiveWinsOverForcedIdle() { XCTAssertTrue(active(idle: true, forced: true)) }

    func testCollapsedIslandRanking() {
        typealias V = NotchRootView
        XCTAssertEqual(V.rank(macNotice: true, agent: true, meeting: true, timerAlone: true), 2, "a volume/brightness change answers at once")
        XCTAssertEqual(V.rank(macNotice: false, agent: true, meeting: true, timerAlone: true), 1, "then the agent comes back")
        XCTAssertEqual(V.rank(macNotice: false, agent: false, meeting: true, timerAlone: true), 4)
        XCTAssertEqual(V.rank(macNotice: false, agent: false, meeting: false, timerAlone: true), 3)
        XCTAssertEqual(V.rank(macNotice: false, agent: false, meeting: false, timerAlone: false), 0)
    }
}

final class ScreenRecorderTests: XCTestCase {
    func testRecordingRanksBelowAgentsAboveMusic() {
        XCTAssertEqual(NotchRootView.rank(macNotice: false, agent: false, meeting: true, timerAlone: true, recording: true), 5)
        XCTAssertEqual(NotchRootView.rank(macNotice: false, agent: true, meeting: false, timerAlone: false, recording: true), 1)
        XCTAssertEqual(ScreenRecorder.elapsed(65), "1:05")
        XCTAssertEqual(ScreenRecorder.elapsed(3723), "1:02:03")
        let name = ScreenRecorder.fileName(at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasPrefix("螢幕錄影 ") && name.hasSuffix(".mov") && !name.contains("/"))
    }
}

final class PermissionsListTests: XCTestCase {
    func testAppSpecificPermissionsOnlyWhenInstalled() {
        let cmux = Permissions.items.first { $0.id == "cmux" }
        XCTAssertNotNil(cmux)
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.cmuxterm.app") != nil
        XCTAssertEqual(Permissions.shown.contains { $0.id == "cmux" }, installed)
        XCTAssertTrue(Permissions.shown.contains { $0.id == "music" }, "always listed")
    }
}
