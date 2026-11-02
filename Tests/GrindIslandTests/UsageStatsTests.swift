import XCTest
@testable import GrindIsland

final class UsageStatsTests: XCTestCase {
    private func line(id: String, ts: String, model: String = "demo-model", cwd: String = "/tmp/demo-project",
                      input: Int = 10, output: Int = 5, type: String = "assistant") -> Data {
        let o: [String: Any] = ["type": type, "timestamp": ts, "cwd": cwd,
                                "message": ["id": id, "model": model, "content": [["type": "text", "text": "not read"]],
                                            "usage": ["input_tokens": input, "output_tokens": output,
                                                      "cache_creation_input_tokens": 100, "cache_read_input_tokens": 1000]]]
        return try! JSONSerialization.data(withJSONObject: o)
    }

    func testReadsOnlyUsageOfAssistantReplies() {
        let r = UsageStats.record(fromLine: line(id: "msg_1", ts: "2026-10-30T14:38:26.155Z"))
        XCTAssertEqual(r?.total, 1115)
        XCTAssertEqual(r?.project, "demo-project")
        XCTAssertNil(UsageStats.record(fromLine: line(id: "msg_2", ts: "2026-10-30T14:38:26Z", type: "user")))
        XCTAssertNil(UsageStats.record(fromLine: Data("{\"type\":\"assistant\"}".utf8)), "no usage")
        XCTAssertNil(UsageStats.record(fromLine: line(id: "msg_3", ts: "2026-10-30T14:38:26Z", model: "<synthetic>")))
        XCTAssertNotNil(UsageStats.record(fromLine: line(id: "msg_4", ts: "2026-10-30T14:38:26Z")), "timestamp without fraction")
        // The same keys written inside a reply's text are escaped, so they are never taken for the real fields.
        let tricky = Data(#"{"type":"assistant","timestamp":"2026-10-30T14:38:26Z","message":{"id":"msg_9","content":[{"type":"text","text":"\"usage\":{\"output_tokens\":999999}"}],"usage":{"input_tokens":1,"output_tokens":2}}}"#.utf8)
        XCTAssertEqual(UsageStats.record(fromLine: tricky)?.output, 2)
    }

    func testSummary() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let now = c.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 15))!
        func rec(_ id: String, daysAgo: Int, hour: Int, project: String, out: Int) -> UsageStats.Record {
            let day = c.date(byAdding: .day, value: -daysAgo, to: c.startOfDay(for: now))!
            return .init(id: id, date: c.date(bySettingHour: hour, minute: 0, second: 0, of: day)!, model: "demo-model",
                         project: project, input: 0, output: out, cacheWrite: 0, cacheRead: 0)
        }
        let s = UsageStats.summarize([rec("a", daysAgo: 0, hour: 9, project: "alpha", out: 100),
                                      rec("b", daysAgo: 0, hour: 9, project: "beta", out: 300),
                                      rec("c", daysAgo: 1, hour: 20, project: "alpha", out: 50),
                                      rec("d", daysAgo: 3, hour: 8, project: "alpha", out: 10),
                                      rec("e", daysAgo: 20, hour: 8, project: "old", out: 999)], now: now, calendar: c)
        XCTAssertEqual(s.todayTokens, 400)
        XCTAssertEqual(s.todayReplies, 2)
        XCTAssertEqual(s.hoursToday[9], 2)
        XCTAssertEqual(s.perDay.count, UsageStats.days)
        XCTAssertEqual(s.perDay.last, 400)
        XCTAssertEqual(s.streak, 2, "today and yesterday; the day before had none")
        XCTAssertEqual(s.topProjects.first?.name, "beta")
        XCTAssertFalse(s.topProjects.contains { $0.name == "old" }, "outside the last 7 days")
        XCTAssertEqual(UsageStats.short(1_234_567), "1.2M")
        XCTAssertEqual(UsageStats.short(34_000), "34K")
    }
}
