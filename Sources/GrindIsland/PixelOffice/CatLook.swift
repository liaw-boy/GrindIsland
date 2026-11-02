import SwiftUI

/// What a cat looks like. Independent of which AI the session belongs to: a look is simply handed to a session.
struct CatLook: Equatable, Identifiable {
    enum Pattern { case solid, tabby, tuxedo, patches, colorpoint }
    enum Ears { case pointed, folded }
    enum Accessory { case none, collar, bow, scarf, glasses, flower }

    let name: String
    var fur: Color
    /// Stripes, patches or the dark "points" (face, ears, paws, tail tip), depending on `pattern`.
    var mark: Color
    /// Second patch color (calico / bicolor); also the muzzle / chest / paw color for a tuxedo.
    var accent: Color
    var eye: Color
    var pattern: Pattern = .solid
    var ears: Ears = .pointed
    var fluffy = false
    var accessory: Accessory = .none
    var accessoryColor: Color = .red

    var id: String { name }

    private static func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    /// The catalog. Add a look here and it is available everywhere.
    static let all: [CatLook] = [
        CatLook(name: "橘虎斑", fur: c(0.96, 0.63, 0.32), mark: c(0.78, 0.42, 0.16), accent: c(1, 0.93, 0.82),
                eye: c(0.55, 0.82, 0.32), pattern: .tabby, accessory: .collar, accessoryColor: c(0.9, 0.25, 0.3)),
        CatLook(name: "灰虎斑", fur: c(0.62, 0.64, 0.68), mark: c(0.38, 0.40, 0.46), accent: c(0.9, 0.9, 0.92),
                eye: c(1, 0.82, 0.28), pattern: .tabby),
        CatLook(name: "黑貓", fur: c(0.17, 0.16, 0.20), mark: c(0.28, 0.27, 0.32), accent: c(0.3, 0.29, 0.34),
                eye: c(0.7, 0.95, 0.3), accessory: .bow, accessoryColor: c(1, 0.5, 0.65)),
        CatLook(name: "白貓", fur: c(0.97, 0.97, 0.99), mark: c(0.85, 0.86, 0.9), accent: c(1, 1, 1),
                eye: c(0.45, 0.72, 1), accessory: .scarf, accessoryColor: c(0.35, 0.6, 0.95)),
        CatLook(name: "三花", fur: c(0.98, 0.97, 0.95), mark: c(0.95, 0.6, 0.25), accent: c(0.2, 0.19, 0.22),
                eye: c(1, 0.82, 0.28), pattern: .patches),
        CatLook(name: "玳瑁", fur: c(0.27, 0.21, 0.19), mark: c(0.86, 0.5, 0.2), accent: c(0.12, 0.1, 0.1),
                eye: c(1, 0.8, 0.25), pattern: .patches, accessory: .flower, accessoryColor: c(1, 0.85, 0.3)),
        CatLook(name: "奶油貓", fur: c(0.99, 0.88, 0.70), mark: c(0.9, 0.7, 0.45), accent: c(1, 0.96, 0.9),
                eye: c(0.55, 0.8, 0.5), pattern: .tabby),
        CatLook(name: "藍灰貓", fur: c(0.55, 0.62, 0.72), mark: c(0.45, 0.52, 0.63), accent: c(0.7, 0.76, 0.84),
                eye: c(0.5, 0.88, 0.5), accessory: .glasses, accessoryColor: c(0.2, 0.2, 0.25)),
        CatLook(name: "暹羅", fur: c(0.96, 0.91, 0.82), mark: c(0.36, 0.26, 0.21), accent: c(0.96, 0.91, 0.82),
                eye: c(0.4, 0.7, 1), pattern: .colorpoint),
        CatLook(name: "賓士", fur: c(0.16, 0.15, 0.18), mark: c(0.3, 0.3, 0.34), accent: c(0.98, 0.98, 0.98),
                eye: c(0.85, 0.9, 0.3), pattern: .tuxedo, accessory: .collar, accessoryColor: c(0.3, 0.65, 0.95)),
        CatLook(name: "摺耳灰", fur: c(0.72, 0.72, 0.76), mark: c(0.5, 0.5, 0.56), accent: c(0.9, 0.9, 0.93),
                eye: c(1, 0.65, 0.2), ears: .folded),
        CatLook(name: "長毛橘", fur: c(0.98, 0.7, 0.4), mark: c(0.86, 0.5, 0.22), accent: c(1, 0.92, 0.8),
                eye: c(0.5, 0.82, 0.4), pattern: .tabby, fluffy: true, accessory: .bow, accessoryColor: c(0.55, 0.4, 0.9)),
        CatLook(name: "銀漸層", fur: c(0.86, 0.88, 0.92), mark: c(0.6, 0.64, 0.72), accent: c(0.97, 0.97, 1),
                eye: c(0.45, 0.85, 0.7), pattern: .tabby, fluffy: true),
        CatLook(name: "巧克力", fur: c(0.46, 0.31, 0.24), mark: c(0.36, 0.24, 0.19), accent: c(0.7, 0.55, 0.45),
                eye: c(1, 0.75, 0.2), accessory: .scarf, accessoryColor: c(0.95, 0.4, 0.35)),
        CatLook(name: "橘白", fur: c(0.98, 0.97, 0.95), mark: c(0.97, 0.66, 0.3), accent: c(0.97, 0.66, 0.3),
                eye: c(0.5, 0.82, 0.4), pattern: .patches),
        CatLook(name: "乳牛貓", fur: c(0.98, 0.98, 0.98), mark: c(0.17, 0.16, 0.2), accent: c(0.17, 0.16, 0.2),
                eye: c(0.9, 0.85, 0.3), pattern: .patches, ears: .folded, accessory: .flower, accessoryColor: c(1, 0.5, 0.6))
    ]

    /// A stable index from a string (FNV-1a), so the same project always gets the same cat.
    static func stableIndex(for key: String, count: Int) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % UInt64(max(count, 1)))
    }

    /// Looks for a set of sessions. Each session's `seed` (its project folder) points at a look through a stable
    /// hash, so the same project keeps the same cat; if another session already has that look, the next free one is
    /// used. The result does not depend on which AI the session belongs to.
    static func assign(_ sessions: [(id: String, seed: String)]) -> [String: CatLook] {
        var taken = Set<Int>(); var result: [String: CatLook] = [:]
        for s in sessions.sorted(by: { ($0.seed, $0.id) < ($1.seed, $1.id) }) {
            var i = stableIndex(for: s.seed, count: all.count)
            var steps = 0
            while taken.contains(i) && steps < all.count { i = (i + 1) % all.count; steps += 1 }
            taken.insert(i); result[s.id] = all[i]
        }
        return result
    }
}
