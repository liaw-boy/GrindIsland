import XCTest
@testable import GrindIsland

final class ScreenshotShelfTests: XCTestCase {
    func testOnlyScreenshotsUnusedForTheWholePeriodGo() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        func d(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        let a = URL(fileURLWithPath: "/tmp/demo/old-unused.png")
        let b = URL(fileURLWithPath: "/tmp/demo/old-but-opened.png")
        let c = URL(fileURLWithPath: "/tmp/demo/new.png")
        let shots: [(url: URL, created: Date, lastUsed: Date?)] = [(a, d(10), nil), (b, d(10), d(1)), (c, d(2), nil)]
        XCTAssertEqual(ScreenshotShelf.stale(shots, now: now, days: 7), [a])
        XCTAssertEqual(ScreenshotShelf.stale(shots, now: now, days: 0), [], "off")
    }
}

final class ScreenshotNameTests: XCTestCase {
    func testOnlyCapturesNamedLikeMacOSOnesAreCleaned() {
        XCTAssertTrue(ScreenshotShelf.ownName("截圖 2026-11-01 20.52.14.png"))
        XCTAssertTrue(ScreenshotShelf.ownName("Screenshot 2026-11-01 at 20.52.14.png"))
        XCTAssertTrue(ScreenshotShelf.ownName("螢幕錄影 2026-11-02 10.06.34.mov"))
        XCTAssertFalse(ScreenshotShelf.ownName("from-a-friend.png"), "someone else's screenshot keeps its own name")
    }
}
