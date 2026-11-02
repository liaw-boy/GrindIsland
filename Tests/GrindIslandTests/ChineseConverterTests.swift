import XCTest
@testable import GrindIsland

final class ChineseConverterTests: XCTestCase {
    func testConvertsSimplifiedToTraditional() {
        XCTAssertEqual(ChineseConverter.toTraditional("爱你的时光"), "愛你的時光")
    }

    func testInsideLiBecomesLiWithRadical() {
        XCTAssertEqual(ChineseConverter.toTraditional("心里"), "心裡")
    }

    func testDistanceWordsKeepLi() {
        XCTAssertEqual(ChineseConverter.toTraditional("千里之外"), "千里之外")
        XCTAssertEqual(ChineseConverter.toTraditional("十公里"), "十公里")
    }

    func testMainlandVocabularyBecomesTaiwan() {
        XCTAssertEqual(ChineseConverter.toTraditional("软件"), "軟體")
        XCTAssertEqual(ChineseConverter.toTraditional("视频"), "影片")
    }

    func testNonChineseTextUnchanged() {
        XCTAssertEqual(ChineseConverter.toTraditional("Hello 123"), "Hello 123")
    }
}
