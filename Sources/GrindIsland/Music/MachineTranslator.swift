import Foundation
import NaturalLanguage
import Translation

/// Fallback translation for songs whose lyric source has none (NetEase only covers part of its catalogue; LRCLIB has
/// none). Runs on-device with Apple's Translation framework, so no lyric text leaves the Mac, and only with
/// language models that are already installed (downloading one needs a system prompt we do not trigger).
enum MachineTranslator {
    /// The language of the lyrics, when they need a translation: no line has one and the text is not Chinese.
    static func sourceLanguage(of doc: LyricDoc) -> Locale.Language? {
        guard !doc.lines.isEmpty, doc.lines.allSatisfy({ $0.translation == nil }) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(doc.lines.map(\.text).joined(separator: "\n"))
        guard let lang = recognizer.dominantLanguage, lang != .undetermined,
              lang != .simplifiedChinese, lang != .traditionalChinese else { return nil }
        return Locale.Language(identifier: lang.rawValue)
    }

    /// The same doc with every line translated to Traditional Chinese, or nil when that is not possible
    /// (macOS before 26, model not installed, or the translation failed).
    static func translate(_ doc: LyricDoc) async -> LyricDoc? {
        guard #available(macOS 26, *), let source = sourceLanguage(of: doc) else { return nil }
        let target = Locale.Language(identifier: "zh-Hant")
        guard await LanguageAvailability().status(from: source, to: target) == .installed else { return nil }
        let session = TranslationSession(installedSource: source, target: target)
        let requests = doc.lines.enumerated().map { TranslationSession.Request(sourceText: $1.text, clientIdentifier: "\($0)") }
        guard let responses = try? await session.translations(from: requests) else { return nil }
        var byIndex: [Int: String] = [:]
        for r in responses { if let i = r.clientIdentifier.flatMap(Int.init) { byIndex[i] = r.targetText } }
        return LyricDoc(lines: doc.lines.enumerated().map { i, l in
            LyricLine(id: l.id, startTime: l.startTime, endTime: l.endTime, text: l.text, translation: byIndex[i])
        })
    }
}
