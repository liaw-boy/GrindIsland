import Foundation

extension Timer {
    /// A timer that keeps firing while a menu is open (e.g. the status bar menu) or a window is being dragged.
    /// `Timer.scheduledTimer` only runs in the default run-loop mode, which macOS pauses during those interactions.
    @discardableResult
    static func commonModeTimer(interval: TimeInterval, repeats: Bool, block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
