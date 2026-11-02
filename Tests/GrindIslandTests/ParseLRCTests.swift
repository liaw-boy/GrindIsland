import XCTest
@testable import GrindIsland

final class ParseLRCTests: XCTestCase {
    func testParsesTimesAndTexts() {
        let doc = LyricService.parseLRC(lrc: "[00:10.50]first line\n[00:15.00]second line", translationLrc: nil)
        XCTAssertEqual(doc.lines.map(\.text), ["first line", "second line"])
        XCTAssertEqual(doc.lines[0].startTime, 10.5, accuracy: 0.001)
        XCTAssertEqual(doc.lines[1].startTime, 15, accuracy: 0.001)
    }

    func testEndTimeIsNextLineStartAndLastGetsFiveSeconds() {
        let doc = LyricService.parseLRC(lrc: "[00:10.00]a\n[00:14.00]b", translationLrc: nil)
        XCTAssertEqual(doc.lines[0].endTime, 14, accuracy: 0.001)
        XCTAssertEqual(doc.lines[1].endTime, 19, accuracy: 0.001)
    }

    func testThreeDigitMillisecondsAreMilliseconds() {
        let doc = LyricService.parseLRC(lrc: "[01:02.345]line", translationLrc: nil)
        XCTAssertEqual(doc.lines[0].startTime, 62.345, accuracy: 0.0001)
    }

    func testIdsAreSequential() {
        let doc = LyricService.parseLRC(lrc: "[00:01.00]a\n[00:02.00]b\n[00:03.00]c", translationLrc: nil)
        XCTAssertEqual(doc.lines.map(\.id), [0, 1, 2])
    }

    func testEmptyTextAndCreditLinesAreDropped() {
        let lrc = "[00:00.00]作词：虚构作者\n[00:00.50]Composer: Someone\n[00:01.00]\n[00:02.00]real line"
        let doc = LyricService.parseLRC(lrc: lrc, translationLrc: nil)
        XCTAssertEqual(doc.lines.map(\.text), ["real line"])
    }

    func testMetadataAndGarbageLinesAreIgnored() {
        let lrc = "[ti:Demo]\n[ar:Nobody]\nnot a lyric\n[00:05.00]kept"
        XCTAssertEqual(LyricService.parseLRC(lrc: lrc, translationLrc: nil).lines.map(\.text), ["kept"])
    }

    func testEmptyInputGivesEmptyDoc() {
        XCTAssertTrue(LyricService.parseLRC(lrc: "", translationLrc: nil).lines.isEmpty)
    }

    func testTranslationMatchesWithinHalfSecond() {
        let doc = LyricService.parseLRC(lrc: "[00:10.00]hello\n[00:20.00]world",
                                        translationLrc: "[00:10.30]你好\n[00:25.00]不相干")
        XCTAssertEqual(doc.lines[0].translation, "你好")
        XCTAssertNil(doc.lines[1].translation)
    }

    func testWindowsLineEndingsStillParse() {
        let doc = LyricService.parseLRC(lrc: "[00:01.00]a\r\n[00:02.00]b\r\n", translationLrc: nil)
        XCTAssertEqual(doc.lines.map(\.text), ["a", "b"])
    }
}

final class NoticeInTranslationTests: XCTestCase {
    func testNetEaseNoticeInTheTranslationIsDropped() {
        let lrc = "[03:57.430]見ないフリしていても\n[04:00.096]確かにそこに君の中に\n[04:07.390]-"
        let tr = "[03:57.430]就算你熟视无睹\n[04:00.096]它确实 就在你心里\n[04:07.390](翻译水平有限 授权网易云音乐使用)"
        let doc = LyricService.parseLRC(lrc: lrc, translationLrc: tr)
        XCTAssertEqual(doc.lines.map(\.text), ["見ないフリしていても", "確かにそこに君の中に"])
        XCTAssertEqual(doc.lines.last?.translation, "它确实 就在你心里")
        XCTAssertTrue(LyricService.isPlaceholder("—"))
        XCTAssertFalse(LyricService.isPlaceholder("♪"))
        XCTAssertFalse(LyricService.isPlaceholder("Oh"))
    }
}
