import XCTest
@testable import GrindIsland

final class ClipboardHistoryTests: XCTestCase {
    typealias H = ClipboardHistory
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testNewestFirstAndRepeatsMoveUp() {
        var items = H.adding("alpha", to: [], now: now)
        items = H.adding("beta", to: items, now: now)
        items = H.adding("alpha", to: items, now: now)
        XCTAssertEqual(items.map(\.text), ["alpha", "beta"])
        XCTAssertEqual(H.adding("   \n", to: items, now: now).count, 2, "blank text is ignored")
        XCTAssertEqual(H.adding(String(repeating: "x", count: H.maxLength + 1), to: items, now: now).count, 2, "too long")
    }

    func testLimitKeepsPinned() {
        var items = H.adding("keep me", to: [], now: now)
        items[0].pinned = true
        for i in 0..<(H.maxItems + 5) { items = H.adding("item \(i)", to: items, now: now) }
        XCTAssertEqual(items.count, H.maxItems)
        XCTAssertTrue(items.contains { $0.text == "keep me" && $0.pinned }, "the oldest, but pinned")
        items = H.adding("keep me", to: items, now: now)
        XCTAssertEqual(items.first?.pinned, true, "copying it again keeps the pin")
    }
}

final class ClipboardPruneTests: XCTestCase {
    func testOldUnpinnedItemsGo() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var old = ClipboardHistory.Item(text: "old", copied: now.addingTimeInterval(-7200))
        let fresh = ClipboardHistory.Item(text: "fresh", copied: now.addingTimeInterval(-60))
        XCTAssertEqual(ClipboardHistory.pruned([fresh, old], now: now, keep: 3600).map(\.text), ["fresh"])
        old.pinned = true
        XCTAssertEqual(ClipboardHistory.pruned([fresh, old], now: now, keep: 3600).map(\.text), ["fresh", "old"], "pinned stays")
    }
}
