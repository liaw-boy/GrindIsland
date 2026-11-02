import Foundation

/// Simplified → Traditional (Taiwan) conversion for translated lyrics. ICU's character-level transform does
/// most of the work; two fix-ups cover what it gets wrong for Taiwan usage.
enum ChineseConverter {
    private static let transform = StringTransform(rawValue: "Hans-Hant")

    /// 里 is ambiguous: "inside" (裡) in lyrics, but a distance / place unit (里) in these words.
    private static let keepLi = ["公里", "千里", "萬里", "英里", "鄉里", "故里", "里程", "里長", "鄰里", "百里", "十里", "里斯本"]

    /// Mainland vocabulary → Taiwan vocabulary (only the ones likely to show up in lyrics).
    private static let vocabulary: [(String, String)] = [
        ("軟件", "軟體"), ("視頻", "影片"), ("信息", "資訊"), ("網絡", "網路"),
        ("程序", "程式"), ("鼠標", "滑鼠"), ("內存", "記憶體"), ("默認", "預設")
    ]

    static func toTraditional(_ text: String) -> String {
        guard var out = text.applyingTransform(transform, reverse: false) else { return text }
        out = out.replacingOccurrences(of: "里", with: "裡")
        for word in keepLi { out = out.replacingOccurrences(of: word.replacingOccurrences(of: "里", with: "裡"), with: word) }
        for (mainland, taiwan) in vocabulary { out = out.replacingOccurrences(of: mainland, with: taiwan) }
        return out
    }
}
