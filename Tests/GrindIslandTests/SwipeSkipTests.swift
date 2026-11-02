import XCTest
@testable import GrindIsland

final class SwipeSkipTests: XCTestCase {
    private func swipe(_ steps: [(CGFloat, CGFloat)]) -> SwipeSkip.Action? {
        var s = SwipeSkip()
        s.begin()
        for (x, y) in steps { s.add(fingerDX: x, fingerDY: y) }
        return s.end()
    }

    func testSwipeLeftIsNext() { XCTAssertEqual(swipe([(-20, 0), (-25, 2)]), .next) }
    func testSwipeRightIsPrevious() { XCTAssertEqual(swipe([(30, 1), (15, 0)]), .previous) }
    func testShortSwipeDoesNothing() { XCTAssertNil(swipe([(-20, 0), (-10, 0)])) }
    func testMostlyVerticalDoesNothing() { XCTAssertNil(swipe([(-50, 40)])) }
    func testBackAndForthCancels() { XCTAssertNil(swipe([(-50, 0), (45, 0)])) }
    func testBeginResets() {
        var s = SwipeSkip()
        s.add(fingerDX: -100, fingerDY: 0)
        s.begin()
        XCTAssertNil(s.end())
    }
}
