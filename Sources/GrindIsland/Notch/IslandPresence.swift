import Combine
import Foundation

/// Decides whether the island should be on screen at all. Every feature that deserves the island
/// (music now, the Agent office later) contributes one source to the merge below.
final class IslandPresence: ObservableObject {
    static let shared = IslandPresence()

    @Published private(set) var isActive = true
    private var cancellables = Set<AnyCancellable>()

    /// The island exists when auto-hide is off, or music is playing, or an agent needs attention. The test
    /// switches (`forcedActive` wins over `forcedIdle`) override everything.
    static func shouldBeActive(autoHideWhenIdle: Bool, playing: Bool, agentAttention: Bool,
                               forceExpanded: Bool, forcedIdle: Bool, forcedActive: Bool) -> Bool {
        if forcedActive { return true }
        if forcedIdle { return false }
        return !autoHideWhenIdle || playing || agentAttention || forceExpanded
    }

    private init() {
        // "Playing" turns true at once, but turns false only after a grace period, so a brief pause
        // (or a track change) does not make the island blink away.
        let playing = MusicTracker.shared.$isPlaying
            .removeDuplicates()
            .map { isPlaying -> AnyPublisher<Bool, Never> in
                isPlaying
                    ? Just(true).eraseToAnyPublisher()
                    : Just(false).delay(for: .seconds(4), scheduler: DispatchQueue.main).eraseToAnyPublisher()
            }
            .switchToLatest()
            .prepend(false)
        // Same rule as `AgentMonitor.noticeSession`: a "waiting" status you just answered from the island does not count,
        // or the island would stay up (showing the music bar) until Claude Code rewrites the status file.
        let monitor = AgentMonitor.shared
        let agentAttention = Publishers.CombineLatest3(monitor.$priorityAlertSession, monitor.$doneNotice, monitor.$pendingApprovals)
            .map { alert, done, pending in !pending.isEmpty || done != nil || alert.map { !monitor.recentlyAnswered($0) } == true }
            .combineLatest(NoticeCenter.shared.$current, FocusTimer.shared.$clock.map(\.isActive).removeDuplicates(),
                           CalendarService.shared.$items.map { AppSettings.shared.meetingAlerts && CalendarService.upcoming(in: $0, now: Date()) != nil }.removeDuplicates())
            .map { agents, notice, timer, meeting in agents || notice != nil || timer || meeting }
            // A screen recording keeps the island up too: its stop button lives there.
            .combineLatest(ScreenRecorder.shared.$started.map { $0 != nil }.removeDuplicates())
            .map { attention, recording in attention || recording }
        // Re-evaluate when preferences change (objectWillChange fires before the new value is stored).
        let settings = AppSettings.shared.objectWillChange.map { _ in () }.prepend(())

        // `--test-idle-at=N` pretends that playback stopped N seconds after launch (so the "island goes idle"
        // animation can be recorded without touching the user's music).
        let forcedIdle = CurrentValueSubject<Bool, Never>(false)
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-idle-at=") }),
           let seconds = Double(arg.dropFirst("--test-idle-at=".count)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { forcedIdle.send(true) }
        }

        // `--test-active-at=N` pretends playback started again N seconds after launch (after `--test-idle-at`).
        let forcedActive = CurrentValueSubject<Bool, Never>(false)
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-active-at=") }),
           let seconds = Double(arg.dropFirst("--test-active-at=".count)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { forcedActive.send(true) }
        }

        Publishers.CombineLatest4(playing, agentAttention, settings, Publishers.CombineLatest(forcedIdle, forcedActive))
            .receive(on: DispatchQueue.main)
            .map { playing, agentAttention, _, forced in
                Self.shouldBeActive(autoHideWhenIdle: AppSettings.shared.autoHideWhenIdle,
                                    playing: playing, agentAttention: agentAttention,
                                    forceExpanded: CommandLine.arguments.contains("--expanded"),
                                    forcedIdle: forced.0, forcedActive: forced.1)
            }
            .removeDuplicates()
            .sink { [weak self] in self?.isActive = $0 }
            .store(in: &cancellables)
    }
}
