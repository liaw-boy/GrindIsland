import XCTest
import SwiftUI
@testable import GrindIsland

final class CalendarServiceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000)

    private func item(startIn m: Double, length: Double = 30) -> CalendarService.Item {
        let s = now.addingTimeInterval(m * 60)
        return .init(id: "e\(m)", title: "Demo sync", start: s, end: s.addingTimeInterval(length * 60), color: .blue, joinURL: nil)
    }

    func testUpcomingWindow() {
        XCTAssertNil(CalendarService.upcoming(in: [item(startIn: 30)], now: now))
        XCTAssertEqual(CalendarService.upcoming(in: [item(startIn: 8)], now: now)?.id, "e8.0")
        XCTAssertEqual(CalendarService.upcoming(in: [item(startIn: -3)], now: now)?.id, "e-3.0", "just started")
        XCTAssertNil(CalendarService.upcoming(in: [item(startIn: -20, length: 60)], now: now), "long past its start")
    }

    func testCountdown() {
        XCTAssertEqual(CalendarService.countdown(to: now.addingTimeInterval(7.5 * 60), now: now), "8 分鐘後")
        XCTAssertEqual(CalendarService.countdown(to: now.addingTimeInterval(-10), now: now), "進行中")
    }

    func testMeetingLinkIsHttpsAndKnownHostOnly() {
        XCTAssertEqual(CalendarService.meetingLink(url: nil, location: nil, notes: "Join: https://meet.google.com/abc-defg-hij")?.host, "meet.google.com")
        XCTAssertNil(CalendarService.meetingLink(url: nil, location: "http://zoom.us/j/1", notes: nil), "not https")
        XCTAssertNil(CalendarService.meetingLink(url: nil, location: nil, notes: "see https://example.com/doc"), "not a meeting host")
        XCTAssertNil(CalendarService.meetingLink(url: URL(string: "file:///etc/hosts"), location: nil, notes: nil))
        XCTAssertNil(CalendarService.meetingLink(url: nil, location: nil, notes: "https://evilzoom.us.example.com/x"))
        XCTAssertNil(CalendarService.meetingLink(url: nil, location: nil, notes: "https://evilzoom.us/j/1"), "suffix without a dot")
        XCTAssertNil(CalendarService.meetingLink(url: URL(string: "https://example.com/x"), location: nil, notes: nil), "event URL must be a meeting host too")
        XCTAssertEqual(CalendarService.meetingLink(url: URL(string: "https://us02web.zoom.us/j/1"), location: nil, notes: nil)?.host, "us02web.zoom.us")
    }
}

final class CalendarTitleTests: XCTestCase {
    func testCleanTitle() {
        XCTAssertEqual(CalendarService.cleanTitle("  Demo\nsync  "), "Demo sync")
        XCTAssertEqual(CalendarService.cleanTitle(String(repeating: "a", count: 500)).count, 200)
        XCTAssertTrue(CalendarService.cleanTitle(" \n ").isEmpty)
    }

    func testMonthCells() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 1
        let oct = c.date(from: DateComponents(year: 2026, month: 10, day: 1))!   // a Thursday
        let cells = CalendarService.monthCells(oct, calendar: c)
        XCTAssertEqual(cells.prefix(4), [nil, nil, nil, nil])
        XCTAssertEqual(cells[4], 1)
        XCTAssertEqual(cells.last, 31)
        c.firstWeekday = 2   // weeks start on Monday
        XCTAssertEqual(CalendarService.monthCells(oct, calendar: c).prefix(4), [nil, nil, nil, 1])
    }

    func testReminderDueDay() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let day11 = c.date(from: DateComponents(year: 2026, month: 11, day: 11))!
        let allDay12 = c.date(from: DateComponents(year: 2026, month: 11, day: 12))!
        let noon11 = c.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
        XCTAssertFalse(CalendarService.isDue(allDay12, on: day11, isToday: false, calendar: c), "next day's all-day reminder")
        XCTAssertTrue(CalendarService.isDue(allDay12, on: allDay12, isToday: false, calendar: c))
        XCTAssertTrue(CalendarService.isDue(noon11, on: day11, isToday: false, calendar: c))
        XCTAssertTrue(CalendarService.isDue(noon11, on: allDay12, isToday: true, calendar: c), "overdue shows today")
        XCTAssertFalse(CalendarService.isDue(noon11, on: allDay12, isToday: false, calendar: c))
    }

    func testRepeatingReminderProjection() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Taipei")!; c.firstWeekday = 1
        func d(_ m: Int, _ day: Int, _ y: Int = 2026) -> Date { c.date(from: DateComponents(year: y, month: m, day: day))! }
        typealias R = CalendarService.Repeat
        let monthly = R(unit: .month)
        XCTAssertTrue(CalendarService.occurs(on: d(12, 12), first: d(11, 12), rule: monthly, calendar: c))
        XCTAssertTrue(CalendarService.occurs(on: d(1, 12, 2027), first: d(11, 12), rule: monthly, calendar: c))
        XCTAssertFalse(CalendarService.occurs(on: d(12, 11), first: d(11, 12), rule: monthly, calendar: c))
        XCTAssertFalse(CalendarService.occurs(on: d(11, 12), first: d(11, 12), rule: monthly, calendar: c), "its own day is the real one")
        XCTAssertFalse(CalendarService.occurs(on: d(12, 12), first: d(11, 12), rule: R(unit: .month, interval: 2), calendar: c))
        XCTAssertTrue(CalendarService.occurs(on: d(11, 30), first: d(10, 31), rule: R(unit: .month, monthDays: [-1]), calendar: c), "last day")
        XCTAssertFalse(CalendarService.occurs(on: d(1, 12, 2027), first: d(11, 12), rule: R(unit: .month, end: d(12, 31)), calendar: c), "ended")
        // Weekly on Mon + Thu (Nov 2 2026 is a Monday), every other week.
        let biweekly = R(unit: .week, interval: 2, weekdays: [2, 5])
        XCTAssertTrue(CalendarService.occurs(on: d(11, 5), first: d(11, 2), rule: biweekly, calendar: c))
        XCTAssertFalse(CalendarService.occurs(on: d(11, 9), first: d(11, 2), rule: biweekly, calendar: c))
        XCTAssertTrue(CalendarService.occurs(on: d(11, 16), first: d(11, 2), rule: biweekly, calendar: c))
        XCTAssertTrue(CalendarService.occurs(on: d(11, 5), first: d(11, 2), rule: R(unit: .day, interval: 3), calendar: c))
        // Every 2 weeks on Sunday + Monday, weeks starting Monday (rule) while the user's weeks start Sunday.
        let monWeeks = R(unit: .week, interval: 2, weekdays: [1, 2], weekStart: 2)
        XCTAssertTrue(CalendarService.occurs(on: d(11, 8), first: d(11, 2), rule: monWeeks, calendar: c), "Sun 11/8 is in the rule's first week")
        XCTAssertFalse(CalendarService.occurs(on: d(11, 15), first: d(11, 2), rule: monWeeks, calendar: c))
        XCTAssertTrue(CalendarService.occurs(on: d(11, 12, 2027), first: d(11, 12), rule: R(unit: .year), calendar: c))
    }
}
