import AppKit
import Combine
import EventKit
import SwiftUI

/// Today's upcoming events from the Mac's calendars (read-only). Access is only requested when the user asks for it
/// on the calendar page, never at launch.
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let color: Color
        /// A meeting link (https only) found in the event's URL, location or notes.
        let joinURL: URL?
        var allDay = false
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var authorized = false
    @Published private(set) var now = Date()
    /// The calendar page: the day whose events are listed.
    @Published var selectedDay = Calendar.current.startOfDay(for: Date()) { didSet { loadPage() } }
    @Published private(set) var dayItems: [Item] = []
    /// The month shown in the mini calendar (its first day) and which of its days have events.
    @Published var shownMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date() { didSet { loadMonth() } }
    @Published private(set) var busyDays = Set<Int>()
    /// Reminders (the Reminders app) due on the selected day; today also lists overdue ones. Separate permission.
    struct Todo: Identifiable, Equatable {
        let id: String; let title: String; let due: Date?; let color: Color; let hasTime: Bool
        /// A later occurrence of a repeating reminder (Reminders only stores the next one): shown, not completable here.
        var projected = false
    }

    /// The parts of a repeat rule we project ourselves.
    struct Repeat: Equatable {
        enum Unit { case day, week, month, year }
        var unit: Unit
        var interval = 1
        var weekdays: [Int] = []     // Calendar weekday numbers (1 = Sunday)
        var monthDays: [Int] = []    // 1…31, -1 = last day
        var end: Date?
        var weekStart = 0             // the rule's own first weekday (0 = the user's)
    }
    @Published private(set) var dayTodos: [Todo] = []
    @Published private(set) var remindersAuthorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    var reminderStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }

    private let store = EKEventStore()
    private var timer: Timer?
    private var announced = Set<String>()
    private var today = Calendar.current.startOfDay(for: Date())

    /// A meeting is "coming up" in the collapsed island from this many seconds before it starts.
    static let leadSeconds: TimeInterval = 10 * 60
    /// …and stays until this long after it started.
    static let graceSeconds: TimeInterval = 5 * 60

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    func start() {
        authorized = status == .fullAccess
        remindersAuthorized = reminderStatus == .fullAccess
        guard authorized || remindersAuthorized, timer == nil else { return }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.reload() }
        reload()
        timer = Timer.commonModeTimer(interval: 30, repeats: true) { [weak self] _ in self?.reload() }
    }

    func requestReminderAccess() {
        store.requestFullAccessToReminders { [weak self] granted, _ in
            DispatchQueue.main.async { self?.remindersAuthorized = granted; if granted { self?.start(); self?.loadTodos() } }
        }
    }

    /// Marks a reminder done in the Reminders app.
    func complete(_ t: Todo) {
        guard remindersAuthorized, let r = store.calendarItem(withIdentifier: t.id) as? EKReminder else { return }
        r.isCompleted = true
        do { try store.save(r, commit: true) } catch { return }
        dayTodos.removeAll { $0.id == t.id }
    }

    private func loadTodos() {
        guard remindersAuthorized else { dayTodos = []; return }
        let cal = Calendar.current
        let day = selectedDay
        let dayEnd = cal.date(byAdding: .day, value: 1, to: day) ?? day
        let isToday = cal.isDateInToday(day)   // today: overdue ones too
        // Everything open up to the end of the day: also the repeating ones whose next due is earlier.
        store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dayEnd, calendars: nil)) { [weak self] found in
            let todos = (found ?? []).compactMap { r -> Todo? in
                let comps = r.dueDateComponents
                guard let due = comps.flatMap({ cal.date(from: $0) }) else { return nil }
                let base = Todo(id: r.calendarItemIdentifier, title: r.title ?? "（無標題）", due: due,
                                color: Color(nsColor: r.calendar?.color ?? .systemOrange), hasTime: comps?.hour != nil)
                if Self.isDue(due, on: day, isToday: isToday, calendar: cal) { return base }
                guard let rule = Self.repeatRule(r), Self.occurs(on: day, first: due, rule: rule, calendar: cal) else { return nil }
                let t = cal.dateComponents([.hour, .minute], from: due)
                let at = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: day) ?? day
                return Todo(id: base.id + "@\(Int(day.timeIntervalSince1970))", title: base.title, due: at,
                            color: base.color, hasTime: base.hasTime, projected: true)
            }
            .sorted { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
            .suffix(50)   // the latest 50 (very old overdue ones drop first)
            DispatchQueue.main.async { if self?.selectedDay == day { self?.dayTodos = Array(todos) } }
        }
    }

    private static func repeatRule(_ r: EKReminder) -> Repeat? {
        guard let rule = r.recurrenceRules?.first else { return nil }
        let unit: Repeat.Unit
        switch rule.frequency {
        case .daily: unit = .day
        case .weekly: unit = .week
        case .monthly: unit = .month
        case .yearly: unit = .year
        @unknown default: return nil
        }
        // shortcut: "repeat N times" ends are ignored (shown forever), and set positions ("2nd Tuesday") are not
        // projected; upgrade if people use them.
        return Repeat(unit: unit, interval: max(1, rule.interval),
                      weekdays: (rule.daysOfTheWeek ?? []).map { $0.dayOfTheWeek.rawValue },
                      monthDays: (rule.daysOfTheMonth ?? []).map(\.intValue),
                      end: rule.recurrenceEnd?.endDate, weekStart: rule.firstDayOfTheWeek)
    }

    /// Whether a reminder first due on `first` and repeating by `rule` comes up again on `day` (after its first day).
    static func occurs(on day: Date, first: Date, rule: Repeat, calendar cal: Calendar) -> Bool {
        let d0 = cal.startOfDay(for: first), d = cal.startOfDay(for: day)
        guard d > d0, rule.end.map({ d <= $0 }) ?? true else { return false }
        func diff(_ c: Calendar.Component) -> Int { cal.dateComponents([c], from: d0, to: d).value(for: c) ?? 0 }
        let dom = cal.component(.day, from: d)
        let lastDom = cal.range(of: .day, in: .month, for: d)?.count ?? 31
        switch rule.unit {
        case .day:
            return diff(.day) % rule.interval == 0
        case .week:
            // "Every 2 weeks" counts weeks the way the rule does, from its own first weekday.
            var cal = cal
            if (1...7).contains(rule.weekStart) { cal.firstWeekday = rule.weekStart }
            guard let w0 = cal.dateInterval(of: .weekOfYear, for: d0)?.start, let w = cal.dateInterval(of: .weekOfYear, for: d)?.start else { return false }
            let weeks = (cal.dateComponents([.day], from: w0, to: w).day ?? 0) / 7
            let days = rule.weekdays.isEmpty ? [cal.component(.weekday, from: d0)] : rule.weekdays
            return weeks % rule.interval == 0 && days.contains(cal.component(.weekday, from: d))
        case .month:
            let months = (cal.component(.year, from: d) - cal.component(.year, from: d0)) * 12 + cal.component(.month, from: d) - cal.component(.month, from: d0)
            let wanted = rule.monthDays.isEmpty ? [cal.component(.day, from: d0)] : rule.monthDays
            // A day past the month's end (31st in a 30-day month) is skipped, like Reminders does.
            return months % rule.interval == 0 && wanted.contains { $0 == dom || ($0 == -1 && dom == lastDom) }
        case .year:
            let years = cal.component(.year, from: d) - cal.component(.year, from: d0)
            return years % rule.interval == 0 && cal.component(.month, from: d) == cal.component(.month, from: d0)
                && dom == cal.component(.day, from: d0)
        }
    }

    /// EventKit's due-date range includes its end, so an all-day reminder for the next day (due at its 00:00) would
    /// also show on this one: keep only those due within the day (today: or earlier, still not done).
    static func isDue(_ due: Date?, on day: Date, isToday: Bool, calendar: Calendar) -> Bool {
        guard let due = due, let end = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
        return due < end && (isToday || due >= day)
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async { if granted { self?.start(); self?.reload() } else { self?.authorized = false } }
        }
    }

    func reload() {
        now = Date()
        rollOverDay()
        let end = Calendar.current.date(byAdding: .hour, value: 18, to: now) ?? now
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-Self.graceSeconds), end: end, calendars: nil)
        items = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)
            .map(Self.item)
        announceStarts()
        loadPage()
        loadMonth()
    }

    /// After midnight a page left on "today" moves to the new today (and its month), instead of staying on yesterday.
    private func rollOverDay() {
        let cal = Calendar.current
        let newToday = cal.startOfDay(for: now)
        guard newToday != today else { return }
        if selectedDay == today { selectedDay = newToday }
        if let oldMonth = cal.dateInterval(of: .month, for: today)?.start, shownMonth == oldMonth,
           let newMonth = cal.dateInterval(of: .month, for: newToday)?.start { shownMonth = newMonth }
        today = newToday
        announced.removeAll()
    }

    /// Days of the shown month with an event or an open reminder (dots in the mini calendar).
    private func loadMonth() {
        let cal = Calendar.current
        let month = shownMonth
        guard let end = cal.date(byAdding: .month, value: 1, to: month) else { return }
        let eventDays = authorized
            ? Set(store.events(matching: store.predicateForEvents(withStart: month, end: end, calendars: nil))
                .filter { $0.startDate >= month }.map { cal.component(.day, from: $0.startDate) })
            : []
        // With reminders the dots are set once, when both are known (no flicker every reload).
        guard remindersAuthorized else { busyDays = eventDays; return }
        store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)) { [weak self] found in
            let monthDays = Self.monthCells(month, calendar: cal).compactMap { $0 }
            var days = Set<Int>()
            for r in found ?? [] {
                guard let due = r.dueDateComponents.flatMap({ cal.date(from: $0) }) else { continue }
                if due >= month && due < end { days.insert(cal.component(.day, from: due)) }
                guard let rule = Self.repeatRule(r) else { continue }
                for n in monthDays where !days.contains(n) {
                    if let d = cal.date(byAdding: .day, value: n - 1, to: month), Self.occurs(on: d, first: due, rule: rule, calendar: cal) { days.insert(n) }
                }
            }
            DispatchQueue.main.async { if self?.shownMonth == month { self?.busyDays = eventDays.union(days) } }
        }
    }

    /// The mini calendar's cells for the month starting at `month`: nil pads the first week, then 1…days.
    static func monthCells(_ month: Date, calendar: Calendar = .current) -> [Int?] {
        guard let days = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + (1...days).map { $0 }
    }

    private static func item(_ e: EKEvent) -> Item {
        Item(id: e.calendarItemIdentifier + "\(e.startDate.timeIntervalSince1970)", title: e.title ?? "（無標題）",
             start: e.startDate, end: e.endDate,
             color: Color(nsColor: e.calendar?.color ?? .systemBlue),
             joinURL: meetingLink(url: e.url, location: e.location, notes: e.notes), allDay: e.isAllDay)
    }

    /// Events of the selected day.
    private func loadPage() {
        loadTodos()
        guard authorized else { return }
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: selectedDay) ?? selectedDay
        dayItems = store.events(matching: store.predicateForEvents(withStart: selectedDay, end: dayEnd, calendars: nil))
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .prefix(30).map(Self.item)
    }

    /// Adds an event to the default calendar. The title is trimmed and capped; returns false if nothing was saved.
    @discardableResult
    func addEvent(title: String, start: Date, minutes: Int) -> Bool {
        let t = Self.cleanTitle(title)
        guard authorized, !t.isEmpty, (5...24 * 60).contains(minutes), let calendar = store.defaultCalendarForNewEvents else { return false }
        let e = EKEvent(eventStore: store)
        e.title = t
        e.startDate = start
        e.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))
        e.calendar = calendar
        do { try store.save(e, span: .thisEvent) } catch { return false }
        reload()
        return true
    }

    static func cleanTitle(_ s: String) -> String {
        String(s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }

    /// The next meeting worth showing in the collapsed island, if one starts within `leadSeconds` (or just started).
    var upcoming: Item? { AppSettings.shared.meetingAlerts ? Self.upcoming(in: items, now: now) : nil }

    static func upcoming(in items: [Item], now: Date) -> Item? {
        items.first { $0.start.timeIntervalSince(now) <= leadSeconds && now.timeIntervalSince($0.start) <= graceSeconds && $0.end > now }
    }

    /// "8 分鐘後" / "進行中".
    static func countdown(to start: Date, now: Date) -> String {
        let m = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return m <= 0 ? "進行中" : "\(m) 分鐘後"
    }

    /// Meeting links are opened in the browser, so only plain https links are accepted.
    static func meetingLink(url: URL?, location: String?, notes: String?) -> URL? {
        let known = ["zoom.us", "meet.google.com", "teams.microsoft.com", "webex.com", "facetime.apple.com"]
        func isMeeting(_ u: URL) -> Bool {
            guard u.scheme?.lowercased() == "https", let h = u.host?.lowercased() else { return false }
            return known.contains { h == $0 || h.hasSuffix("." + $0) }
        }
        if let u = url, isMeeting(u) { return u }
        let text = [location, notes].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return det.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first(where: isMeeting)
    }

    func join(_ item: Item) {
        guard let u = item.joinURL, u.scheme?.lowercased() == "https" else { return }
        NSWorkspace.shared.open(u)
    }

    /// One notice when a meeting starts.
    private func announceStarts() {
        guard AppSettings.shared.meetingAlerts else { return }
        for i in items where !announced.contains(i.id) && i.start <= now && now.timeIntervalSince(i.start) < 60 {
            announced.insert(i.id)
            NoticeCenter.shared.post(IslandNotice(icon: "calendar", tint: i.color, title: "會議開始",
                                                  detail: i.title, trailing: "現在"), seconds: 6)
        }
    }
}

/// The expanded "行事曆" page: the system's month calendar on the left, the selected day's events (and a form to add
/// one) on the right.
struct CalendarPageView: View {
    @ObservedObject private var cal = CalendarService.shared
    @State private var adding = false
    @State private var newTitle = ""
    @State private var newStart = Date()
    @State private var newMinutes = 30
    @FocusState private var titleFocused: Bool
    private let calendar = Calendar.current

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MiniMonth().frame(width: 200)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1).padding(.vertical, 4)
            Group {
                if !cal.authorized { accessPrompt }
                else if adding { addForm.transition(.move(edge: .trailing).combined(with: .opacity)) }
                else { eventsSide.transition(.move(edge: .leading).combined(with: .opacity)) }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: adding)
        }
        .padding(.horizontal, 22).padding(.top, 2).padding(.bottom, 6)
        .environment(\.colorScheme, .dark)
        .onAppear { cal.start(); if cal.authorized { cal.reload() } }
        .onDisappear { setAdding(false) }
    }

    private var accessPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 22)).foregroundColor(.white.opacity(0.6))
            Text(cal.status == .denied || cal.status == .restricted
                 ? "沒有行事曆權限，可到「系統設定 › 隱私權與安全性 › 行事曆」開啟"
                 : "允許後可在這裡看到每天的行程、新增行程，並在會議前提醒")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.6)).multilineTextAlignment(.center)
            if cal.status == .notDetermined {
                Button { cal.requestAccess() } label: {
                    Text("允許讀取行事曆").font(.system(size: 12, weight: .bold)).foregroundColor(.black)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color.green)).contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Events of the day

    private var eventsSide: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dayTitle).font(.system(size: 12, weight: .bold)).foregroundColor(.white.opacity(0.9))
                Spacer()
                Button { setAdding(true) } label: {
                    Label("新增", systemImage: "plus").font(.system(size: 11, weight: .semibold)).foregroundColor(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.9))).contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if cal.dayItems.isEmpty && cal.dayTodos.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 18)).foregroundColor(.white.opacity(0.4))
                    Text(cal.remindersAuthorized ? "這天沒有行程和提醒事項" : "這天沒有行程").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    remindersButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(cal.dayItems) { row($0) }
                        ForEach(cal.dayTodos) { todoRow($0).transition(.opacity.combined(with: .move(edge: .leading))) }
                        remindersButton
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: cal.dayTodos)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Asks for Reminders access only when the user taps it.
    @ViewBuilder private var remindersButton: some View {
        if cal.reminderStatus == .notDetermined {
            Button { cal.requestReminderAccess() } label: {
                Label("一併顯示提醒事項", systemImage: "checklist").font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.orange).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.top, 2)
        }
    }

    /// A reminder: tap the circle to mark it done in the Reminders app.
    private func todoRow(_ t: CalendarService.Todo) -> some View {
        let overdue = !t.projected && (t.due.map { $0 < (t.hasTime ? cal.now : calendar.startOfDay(for: cal.now)) } ?? false)
        return HStack(spacing: 8) {
            if t.projected {
                // A later repeat: completing it here would tick off the current one instead.
                Image(systemName: "repeat").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(t.color.opacity(0.8)).frame(width: 18, height: 18).help("重複的提醒事項")
            } else {
                Button { withAnimation { cal.complete(t) } } label: {
                    Image(systemName: "circle").font(.system(size: 14, weight: .medium)).foregroundColor(t.color)
                        .frame(width: 18, height: 18).contentShape(Circle())
                }
                .buttonStyle(.plain).help("標示為完成")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                if let d = t.due {
                    Text(overdue ? "逾期・\(d.formatted(.dateTime.month().day()))"
                         : (t.projected ? "重複・" : "") + (t.hasTime ? d.formatted(date: .omitted, time: .shortened) : "提醒事項"))
                        .font(.system(size: 10)).monospacedDigit().foregroundColor(overdue ? .red.opacity(0.85) : .white.opacity(0.5))
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    private var dayTitle: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_Hant_TW"); f.dateFormat = "M 月 d 日 EEEE"
        return (calendar.isDateInToday(cal.selectedDay) ? "今天・" : "") + f.string(from: cal.selectedDay)
    }

    private func row(_ i: CalendarService.Item) -> some View {
        let past = i.end < cal.now
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(i.color).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(i.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text(i.allDay ? "整天" : "\(i.start.formatted(date: .omitted, time: .shortened)) – \(i.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).monospacedDigit().foregroundColor(.white.opacity(0.5))
            }
            Spacer(minLength: 4)
            if !i.allDay, i.start > cal.now, i.start.timeIntervalSince(cal.now) < 3 * 3600 {
                Text(CalendarService.countdown(to: i.start, now: cal.now)).font(.system(size: 10, weight: .medium)).foregroundColor(i.color)
            }
            if i.joinURL != nil, !past {
                Button { cal.join(i) } label: {
                    Text("加入").font(.system(size: 10, weight: .bold)).foregroundColor(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.green)).contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        .opacity(past ? 0.45 : 1)
    }

    // MARK: Add an event

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("新增到 \(dayTitle)").font(.system(size: 12, weight: .bold)).foregroundColor(.white.opacity(0.9))
            TextField("行程名稱", text: $newTitle)
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.1)))
                .focused($titleFocused)
                .onSubmit(save)
            HStack(spacing: 8) {
                DatePicker("", selection: $newStart, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                Picker("", selection: $newMinutes) {
                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text($0 < 60 ? "\($0) 分鐘" : "\(Double($0) / 60, specifier: "%g") 小時").tag($0) }
                }
                .labelsHidden().fixedSize()
                Spacer()
                Button("取消") { setAdding(false) }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
                Button(action: save) {
                    Text("加入行程").font(.system(size: 11, weight: .bold)).foregroundColor(.black)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.green)).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(CalendarService.cleanTitle(newTitle).isEmpty)
                .opacity(CalendarService.cleanTitle(newTitle).isEmpty ? 0.4 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func setAdding(_ on: Bool) {
        if on {
            // Next half hour on the selected day.
            let now = Date()
            let base = calendar.isDate(cal.selectedDay, inSameDayAs: now) ? now : (calendar.date(bySettingHour: 9, minute: 0, second: 0, of: cal.selectedDay) ?? now)
            let m = calendar.component(.minute, from: base)
            newStart = calendar.date(byAdding: .minute, value: (30 - m % 30) % 30, to: base) ?? base
            newTitle = ""
        }
        NotchPanel.acceptKeyboard(on)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { adding = on }
        if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { titleFocused = true } }
    }

    private func save() {
        // The day can change in the month picker while the form is open: take the day from it, the time from the form.
        let hm = calendar.dateComponents([.hour, .minute], from: newStart)
        let start = calendar.date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0, second: 0, of: cal.selectedDay) ?? newStart
        guard cal.addEvent(title: newTitle, start: start, minutes: newMinutes) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        setAdding(false)
    }
}

/// A month in the style of the macOS Calendar widget: red month name, today in a red disc, dots under busy days.
struct MiniMonth: View {
    @ObservedObject private var cal = CalendarService.shared
    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(monthTitle).font(.system(size: 12, weight: .bold)).foregroundColor(.red)
                Spacer()
                arrow("chevron.left", -1)
                arrow("chevron.right", 1)
            }
            .padding(.horizontal, 3)
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, d in
                    Text(d).font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                }
                ForEach(Array(CalendarService.monthCells(cal.shownMonth).enumerated()), id: \.offset) { _, day in
                    if let day = day { cell(day) } else { Color.clear.frame(height: 16) }
                }
            }
        }
    }

    private func cell(_ day: Int) -> some View {
        let date = calendar.date(byAdding: .day, value: day - 1, to: cal.shownMonth) ?? cal.shownMonth
        let today = calendar.isDateInToday(date)
        let selected = calendar.isDate(date, inSameDayAs: cal.selectedDay)
        return Button { cal.selectedDay = calendar.startOfDay(for: date) } label: {
            Text("\(day)").font(.system(size: 10.5, weight: today || selected ? .bold : .medium)).monospacedDigit()
                .foregroundColor(today ? .white : selected ? .black : .white.opacity(0.9))
                .frame(width: 18, height: 16)
                .background(Circle().fill(today ? Color.red : selected ? Color.white.opacity(0.9) : .clear).frame(width: 17, height: 17))
                .overlay(alignment: .bottom) {
                    if cal.busyDays.contains(day) && !today && !selected {
                        Circle().fill(Color.white.opacity(0.5)).frame(width: 2.5, height: 2.5).offset(y: 2.5)
                    }
                }
                .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func arrow(_ icon: String, _ step: Int) -> some View {
        Button {
            withAnimation(.snappy) { cal.shownMonth = calendar.date(byAdding: .month, value: step, to: cal.shownMonth) ?? cal.shownMonth }
        } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.6))
                .frame(width: 18, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var monthTitle: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = calendar.component(.year, from: cal.shownMonth) == calendar.component(.year, from: Date()) ? "M月" : "y年M月"
        return f.string(from: cal.shownMonth)
    }

    /// 日 一 二 … starting from the user's first weekday.
    private var weekdays: [String] {
        let s = ["日", "一", "二", "三", "四", "五", "六"]
        return (0..<7).map { s[(calendar.firstWeekday - 1 + $0) % 7] }
    }
}
