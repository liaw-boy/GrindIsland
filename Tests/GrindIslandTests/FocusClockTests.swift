import XCTest
@testable import GrindIsland

final class FocusClockTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let p = FocusClock.Preset(focus: 25, rest: 5)

    func testFocusThenRestThenStop() {
        var c = FocusClock()
        c.start(p, at: t0)
        XCTAssertEqual(c.remaining(at: t0.addingTimeInterval(60)), 24 * 60)
        XCTAssertNil(c.tick(at: t0.addingTimeInterval(24 * 60)))
        XCTAssertEqual(c.tick(at: t0.addingTimeInterval(25 * 60)), .focus)
        XCTAssertEqual(c.phase, .rest)
        XCTAssertEqual(c.cycles, 1)
        XCTAssertEqual(c.tick(at: t0.addingTimeInterval(30 * 60)), .rest)
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(c.cycles, 1)
    }

    func testPauseKeepsTheTimeLeft() {
        var c = FocusClock()
        c.start(p, at: t0)
        c.pause(at: t0.addingTimeInterval(600))
        XCTAssertFalse(c.isRunning)
        XCTAssertEqual(c.remaining(at: t0.addingTimeInterval(9999)), 15 * 60)
        c.resume(at: t0.addingTimeInterval(9999))
        XCTAssertEqual(c.remaining(at: t0.addingTimeInterval(9999 + 60)), 14 * 60)
    }

    func testFormat() {
        XCTAssertEqual(FocusClock.format(25 * 60), "25:00")
        XCTAssertEqual(FocusClock.format(59.2), "1:00")
        XCTAssertEqual(FocusClock.format(0), "0:00")
    }
}
