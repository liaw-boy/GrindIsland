import CoreGraphics

/// Two-finger horizontal swipe on the collapsed island: left = next track, right = previous track.
/// Pure accumulator, so the gesture rules are testable without a trackpad.
struct SwipeSkip {
    enum Action: Equatable { case next, previous }

    /// Finger travel (pt) needed before a swipe counts.
    static let threshold: CGFloat = 40

    private var dx: CGFloat = 0
    private var dy: CGFloat = 0

    mutating func begin() { dx = 0; dy = 0 }

    /// `fingerDX` / `fingerDY`: movement in the direction the fingers moved (positive = right / down).
    mutating func add(fingerDX: CGFloat, fingerDY: CGFloat) { dx += fingerDX; dy += fingerDY }

    /// Called when the fingers lift. Mostly-vertical or short movements do nothing.
    func end() -> Action? {
        guard abs(dx) >= Self.threshold, abs(dx) >= 2 * abs(dy) else { return nil }
        return dx < 0 ? .next : .previous
    }
}
