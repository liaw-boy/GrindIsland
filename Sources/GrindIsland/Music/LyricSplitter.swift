import AppKit

/// Splits lyric lines that are too wide for the collapsed island into shorter lines. Each part gets a
/// share of the original line's time proportional to its width, and keeps the full translation.
enum LyricSplitter {
    private static let noBreakBefore = Set("ゃゅょっぁぃぅぇぉゎャュョッァィゥェォヮー、。，．！？!?,.」』）)・…~〜")
    private static let noBreakAfter = Set("「『（(")
    private static let softBreakAfter = Set(" 　、。，,!?！？…・")

    /// - Parameter translationFontSize: when set, the translation is split into the same number of parts as the
    ///   lyric (for the side-by-side layout); otherwise every part keeps the whole translation.
    static func split(_ doc: LyricDoc, maxWidth: CGFloat, fontSize: CGFloat, translationFontSize: CGFloat? = nil) -> LyricDoc {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let translationFont = translationFontSize.map { NSFont.systemFont(ofSize: $0, weight: .medium) }
        var out: [LyricLine] = []

        for line in doc.lines {
            let parts = splitText(line.text, maxWidth: maxWidth, font: font)
            guard parts.count > 1 else { out.append(line); continue }

            var translations = [String?](repeating: line.translation, count: parts.count)
            if let tr = line.translation, let tf = translationFont {
                let tp = splitText(tr, maxWidth: .greatestFiniteMagnitude, font: tf, forcedParts: parts.count)
                if tp.count == parts.count { translations = tp }
            }

            let widths = parts.map { width($0, font) }
            let total = max(widths.reduce(0, +), 1)
            // Share only the time that is actually sung; the instrumental tail stays with the last part.
            let duration = line.sweepDuration
            var start = line.startTime
            for (i, part) in parts.enumerated() {
                let end = i == parts.count - 1 ? line.endTime : start + duration * Double(widths[i] / total)
                out.append(LyricLine(id: 0, startTime: start, endTime: end, text: part, translation: translations[i]))
                start = end
            }
        }

        let renumbered = out.enumerated().map { idx, l in
            LyricLine(id: idx, startTime: l.startTime, endTime: l.endTime, text: l.text, translation: l.translation)
        }
        return LyricDoc(lines: renumbered)
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    private static func isHiragana(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3041...0x309F).contains(v)
    }

    private static func isKanjiOrKatakana(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x30A1...0x30FA).contains(v)
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "'")
    }

    private static func splitText(_ text: String, maxWidth: CGFloat, font: NSFont, forcedParts: Int? = nil) -> [String] {
        let chars = Array(text)
        if let forced = forcedParts {
            guard chars.count >= forced, forced > 1 else { return [text] }
        } else {
            guard chars.count > 1, width(text, font) > maxWidth else { return [text] }
        }

        // cum[k] = width of the first k characters
        var cum: [CGFloat] = [0]
        for k in 1...chars.count { cum.append(width(String(chars[0..<k]), font)) }
        let total = cum[chars.count]
        let n = forcedParts ?? max(2, Int((total / maxWidth).rounded(.up)))

        // Positions k where a break before chars[k] is acceptable.
        var candidates: [Int] = []
        for k in 1..<chars.count {
            let prev = chars[k - 1], next = chars[k]
            if isWordChar(prev) && isWordChar(next) { continue }        // never split inside a word
            if noBreakBefore.contains(next) || noBreakAfter.contains(prev) { continue }
            candidates.append(k)
        }
        guard !candidates.isEmpty else { return [text] }

        var cuts: [Int] = []
        for j in 1..<n {
            let target = total * CGFloat(j) / CGFloat(n)
            let best = candidates
                .filter { k in cuts.last.map { k > $0 } ?? true }
                .min { a, b in
                    func score(_ k: Int) -> CGFloat {
                        var s = abs(cum[k] - target)
                        if softBreakAfter.contains(chars[k - 1]) { s -= 70 }          // space / punctuation
                        else if isHiragana(chars[k - 1]) && isKanjiOrKatakana(chars[k]) { s -= 35 }  // phrase boundary
                        return s
                    }
                    return score(a) < score(b)
                }
            if let k = best { cuts.append(k) }
        }

        var parts: [String] = []
        var from = 0
        for k in cuts + [chars.count] {
            let piece = String(chars[from..<k]).trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { parts.append(piece) }
            from = k
        }
        return parts.isEmpty ? [text] : parts
    }
}
