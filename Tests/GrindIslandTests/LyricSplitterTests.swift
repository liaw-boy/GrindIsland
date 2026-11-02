import XCTest
@testable import GrindIsland

final class LyricSplitterTests: XCTestCase {
    private func doc(_ text: String, translation: String? = nil) -> LyricDoc {
        LyricDoc(lines: [LyricLine(id: 0, startTime: 10, endTime: 20, text: text, translation: translation)])
    }

    func testShortLineIsNotSplit() {
        let out = LyricSplitter.split(doc("你好"), maxWidth: 500, fontSize: 14)
        XCTAssertEqual(out.lines.count, 1)
        XCTAssertEqual(out.lines[0].text, "你好")
    }

    func testLongLineSplitsWithoutLosingCharacters() {
        let text = "今天的天空很藍，我們一起走過長長的街道，看著夕陽慢慢落下"
        let out = LyricSplitter.split(doc(text), maxWidth: 120, fontSize: 14)
        XCTAssertGreaterThan(out.lines.count, 1)
        XCTAssertEqual(out.lines.map(\.text).joined().replacingOccurrences(of: " ", with: ""), text)
    }

    func testSplitPartsStayWithinOriginalTimeAndAreContiguous() {
        let out = LyricSplitter.split(doc("今天的天空很藍，我們一起走過長長的街道，看著夕陽慢慢落下"), maxWidth: 120, fontSize: 14)
        XCTAssertEqual(out.lines.first?.startTime, 10)
        XCTAssertEqual(out.lines.last?.endTime, 20)
        for (a, b) in zip(out.lines, out.lines.dropFirst()) {
            XCTAssertEqual(a.endTime, b.startTime, accuracy: 0.0001)
            XCTAssertLessThan(a.startTime, a.endTime)
        }
    }

    func testIdsAreRenumberedSequentially() {
        let two = LyricDoc(lines: [
            LyricLine(id: 7, startTime: 0, endTime: 5, text: "短"),
            LyricLine(id: 9, startTime: 5, endTime: 15, text: "今天的天空很藍，我們一起走過長長的街道，看著夕陽慢慢落下")
        ])
        let out = LyricSplitter.split(two, maxWidth: 120, fontSize: 14)
        XCTAssertEqual(out.lines.map(\.id), Array(0..<out.lines.count))
    }

    func testEveryPartKeepsFullTranslationByDefault() {
        let out = LyricSplitter.split(doc("今天的天空很藍，我們一起走過長長的街道，看著夕陽慢慢落下", translation: "The sky is blue."),
                                      maxWidth: 120, fontSize: 14)
        XCTAssertTrue(out.lines.allSatisfy { $0.translation == "The sky is blue." })
    }

    func testNeverBreaksInsideLatinWord() {
        let out = LyricSplitter.split(doc("wonderful everything beautiful tomorrow"), maxWidth: 110, fontSize: 14)
        let words = Set(["wonderful", "everything", "beautiful", "tomorrow"])
        for l in out.lines { for w in l.text.split(separator: " ") { XCTAssertTrue(words.contains(String(w)), "broken word: \(w)") } }
    }

    func testNoBreakBeforeClosingPunctuation() {
        let out = LyricSplitter.split(doc("我們一起走過長長的街道，看著夕陽慢慢落下。再見"), maxWidth: 120, fontSize: 14)
        for l in out.lines.dropFirst() {
            XCTAssertFalse("，。！？、".contains(l.text.first!), "line starts with punctuation: \(l.text)")
        }
    }
}
