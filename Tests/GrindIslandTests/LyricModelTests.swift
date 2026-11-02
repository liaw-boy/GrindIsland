import XCTest
@testable import GrindIsland

final class LyricModelTests: XCTestCase {
    func testCreditLinesAreDetected() {
        XCTAssertTrue(LyricService.isCreditLine("作词：某某"))
        XCTAssertTrue(LyricService.isCreditLine("作曲 : 某某"))
        XCTAssertTrue(LyricService.isCreditLine("Composer: Someone"))
        XCTAssertTrue(LyricService.isCreditLine("Produced by: Someone"))
        XCTAssertTrue(LyricService.isCreditLine("词：某某"))
    }

    func testNormalLyricLinesAreKept() {
        XCTAssertFalse(LyricService.isCreditLine("今天天气很好"))
        XCTAssertFalse(LyricService.isCreditLine("I said: hello world"))
        XCTAssertFalse(LyricService.isCreditLine("这是一句很长很长很长很长很长的前缀文字：后面内容"))
    }

    func testSingingTimeHasMinimum() {
        XCTAssertEqual(LyricLine.estimatedSingingTime(for: "a"), 1.2)
        XCTAssertEqual(LyricLine.estimatedSingingTime(for: ""), 1.2)
    }

    func testSingingTimeCountsCJKLongerThanLatin() {
        let cjk = LyricLine.estimatedSingingTime(for: "一二三四五六七八")
        let latin = LyricLine.estimatedSingingTime(for: "abcdefgh")
        XCTAssertGreaterThan(cjk, latin)
    }

    func testSweepUsesWholeGapWhenNotInstrumental() {
        let line = LyricLine(id: 0, startTime: 10, endTime: 14, text: "一二三四五六七八九十")
        XCTAssertEqual(line.sweepDuration, 4, accuracy: 0.001)
    }

    func testSweepShortensWhenGapIsMostlyInstrumental() {
        let line = LyricLine(id: 0, startTime: 10, endTime: 40, text: "短句")
        XCTAssertLessThan(line.sweepDuration, 30)
        XCTAssertEqual(line.sweepDuration, LyricLine.estimatedSingingTime(for: "短句") * 1.25, accuracy: 0.001)
    }

    func testConvertingTranslationsOnlyTouchesTranslation() {
        let doc = LyricDoc(lines: [LyricLine(id: 0, startTime: 1, endTime: 2, text: "原文", translation: "abc"),
                                   LyricLine(id: 1, startTime: 2, endTime: 3, text: "无翻译")])
        let out = doc.convertingTranslations { $0.uppercased() }
        XCTAssertEqual(out.lines[0].translation, "ABC")
        XCTAssertEqual(out.lines[0].text, "原文")
        XCTAssertNil(out.lines[1].translation)
    }
}

final class CopyrightLineTests: XCTestCase {
    func testYearOfWorkNoticeIsDetected() {
        XCTAssertTrue(LyricService.isCopyrightLine("(2020年作品)"))
        XCTAssertTrue(LyricService.isCopyrightLine("（2019年作品）"))
        XCTAssertTrue(LyricService.isCopyrightLine("（ 2018 年作 ）"))
    }

    func testAuthorizationNoticeIsDetected() {
        XCTAssertTrue(LyricService.isCopyrightLine("授权网易云音乐使用"))
        XCTAssertTrue(LyricService.isCopyrightLine("本歌曲由某某公司授權某平台使用"))
        XCTAssertTrue(LyricService.isCopyrightLine("未经许可，不得翻唱或使用"))
    }

    func testCopyrightSymbolsAreDetected() {
        XCTAssertTrue(LyricService.isCopyrightLine("版权所有 某某公司"))
        XCTAssertTrue(LyricService.isCopyrightLine("© 2020 Example Records"))
        XCTAssertTrue(LyricService.isCopyrightLine("Copyright 2020 Example Records"))
        XCTAssertTrue(LyricService.isCopyrightLine("℗ 2021 Example Records"))
        XCTAssertTrue(LyricService.isCopyrightLine("某某公司享有本翻译作品的著作权"))
        XCTAssertTrue(LyricService.isCopyrightLine("未经著作权人书面许可，不得以任何方式使用"))
        XCTAssertTrue(LyricService.isCopyrightLine("本歌曲来自〖某某工作室〗"))
        XCTAssertFalse(LyricService.isCopyrightLine("我享有這片天空"))
    }

    func testOrdinaryLyricsAreKept() {
        XCTAssertFalse(LyricService.isCopyrightLine("我授权你爱我"))
        XCTAssertFalse(LyricService.isCopyrightLine("2020年的夏天我们相遇"))
        XCTAssertFalse(LyricService.isCopyrightLine("(哦哦哦)"))
        XCTAssertFalse(LyricService.isCopyrightLine("Use me up"))
    }

    func testParseLRCDropsTrailingCopyrightLines() {
        let lrc = "[00:10.00]real line\n[03:30.00](2020年作品)\n[03:31.00]授权网易云音乐使用"
        XCTAssertEqual(LyricService.parseLRC(lrc: lrc, translationLrc: nil).lines.map(\.text), ["real line"])
    }
}

final class InterludeTests: XCTestCase {
    // "la" is sung in ~1.2s * 1.25 = 1.5s, so the sung part ends at 11.5.
    private let line = LyricLine(id: 0, startTime: 10, endTime: 30, text: "la")

    func testMiddleOfLongBreakIsInterlude() { XCTAssertTrue(line.isInterlude(at: 20)) }
    func testWhileSingingIsNot() { XCTAssertFalse(line.isInterlude(at: 11)) }
    func testJustBeforeNextLineIsNot() { XCTAssertFalse(line.isInterlude(at: 29)) }
    func testShortGapIsNever() {
        let short = LyricLine(id: 0, startTime: 10, endTime: 16, text: "la")
        XCTAssertFalse(short.isInterlude(at: 13))
    }
    func testProgressRunsZeroToOne() {
        let a = line.interludeProgress(at: 13.1)!, b = line.interludeProgress(at: 28.4)!
        XCTAssertLessThan(a, 0.05)
        XCTAssertGreaterThan(b, 0.95)
    }
}

final class MachineTranslatorTests: XCTestCase {
    private func doc(_ texts: [String], translated: Bool = false) -> LyricDoc {
        LyricDoc(lines: texts.enumerated().map {
            LyricLine(id: $0, startTime: Double($0) * 4, endTime: Double($0 + 1) * 4, text: $1, translation: translated ? "譯文" : nil)
        })
    }

    func testJapaneseWithoutTranslationNeedsOne() {
        XCTAssertEqual(MachineTranslator.sourceLanguage(of: doc(["夢ならばどれほどよかったでしょう", "未だにあなたのことを夢にみる"]))?.minimalIdentifier, "ja")
    }

    func testChineseOrAlreadyTranslatedIsLeftAlone() {
        XCTAssertNil(MachineTranslator.sourceLanguage(of: doc(["我們一起走過的日子", "還留在心裡"])))
        XCTAssertNil(MachineTranslator.sourceLanguage(of: doc(["Hello from the other side"], translated: true)))
        XCTAssertNil(MachineTranslator.sourceLanguage(of: doc([])))
    }
}

final class RepeatModeTests: XCTestCase {
    func testCyclesLikeMusic() {
        XCTAssertEqual(MusicTracker.nextRepeat("off"), "all")
        XCTAssertEqual(MusicTracker.nextRepeat("all"), "one")
        XCTAssertEqual(MusicTracker.nextRepeat("one"), "off")
        XCTAssertEqual(MusicTracker.repeatMode("ALL"), "all")
        XCTAssertEqual(MusicTracker.repeatMode("missing value"), "off")
    }
}
