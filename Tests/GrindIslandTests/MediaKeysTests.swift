import XCTest
@testable import GrindIsland

final class MediaKeysTests: XCTestCase {
    func testDecodesSpecialKeys() {
        func data1(_ code: Int, down: Bool) -> Int { (code << 16) | ((down ? 0xA : 0xB) << 8) }
        XCTAssertEqual(MediaKeys.decode(data1: data1(0, down: true))?.0, .volumeUp)
        XCTAssertEqual(MediaKeys.decode(data1: data1(1, down: true))?.0, .volumeDown)
        XCTAssertEqual(MediaKeys.decode(data1: data1(7, down: false))?.down, false)
        XCTAssertEqual(MediaKeys.decode(data1: data1(2, down: true))?.0, .brightnessUp)
        XCTAssertEqual(MediaKeys.decode(data1: data1(22, down: true))?.0, .lightDown)
        XCTAssertNil(MediaKeys.decode(data1: data1(16, down: true)), "play/pause is left to macOS")
        XCTAssertNil(MediaKeys.decode(data1: (0 << 16) | (0x5 << 8)), "not a key state")
    }

    func testSteps() {
        XCTAssertEqual(MediaKeys.next(0.5, up: true, fine: false), 0.5625, accuracy: 0.0001)
        XCTAssertEqual(MediaKeys.next(0.51, up: false, fine: false), 0.4375, accuracy: 0.0001, "snaps to the grid")
        XCTAssertEqual(MediaKeys.next(1, up: true, fine: false), 1)
        XCTAssertEqual(MediaKeys.next(0, up: false, fine: false), 0)
        XCTAssertEqual(MediaKeys.next(0.5, up: true, fine: true), 0.515625, accuracy: 0.0001, "⌥⇧ quarter step")
    }
}
