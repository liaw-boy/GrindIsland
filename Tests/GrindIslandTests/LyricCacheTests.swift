import XCTest
@testable import GrindIsland

final class LyricCacheTests: XCTestCase {
    private var dir: URL!
    private var cache: LyricCache!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyriccache-test-\(UUID().uuidString)", isDirectory: true)
        cache = LyricCache(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func load(_ key: String, days: Int = 14) -> LyricPayload? {
        let done = expectation(description: "load")
        var result: LyricPayload?
        cache.load(key: key, days: days) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }

    private func settle() { _ = cache.count() }   // count() runs on the cache's serial queue, so earlier writes are done

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
    }

    func testStoreThenLoadRoundTrips() {
        cache.store(key: "demo-track", payload: LyricPayload(lrc: "[00:01.00]hi", translation: "嗨"))
        settle()
        XCTAssertEqual(load("demo-track"), LyricPayload(lrc: "[00:01.00]hi", translation: "嗨"))
    }

    func testMissingKeyIsAMiss() {
        XCTAssertNil(load("never-stored"))
    }

    func testFileNameIsHashNotTrackKey() {
        cache.store(key: "Some Title - Some Artist", payload: LyricPayload(lrc: "x", translation: nil))
        settle()
        let names = files().map(\.lastPathComponent)
        XCTAssertEqual(names.count, 1)
        XCTAssertFalse(names[0].localizedCaseInsensitiveContains("title"))
        XCTAssertEqual(names[0].count, 64 + ".json".count)
    }

    func testExpiredEntryIsMissAndDeleted() throws {
        cache.store(key: "old", payload: LyricPayload(lrc: "x", translation: nil))
        settle()
        let old = Date().addingTimeInterval(-15 * 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: files()[0].path)
        XCTAssertNil(load("old", days: 14))
        XCTAssertTrue(files().isEmpty)
    }

    func testRecentEntryWithinRetentionIsKept() throws {
        cache.store(key: "recent", payload: LyricPayload(lrc: "x", translation: nil))
        settle()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: files()[0].path)
        XCTAssertNotNil(load("recent", days: 14))
    }

    func testPlayingRefreshesLastPlayed() throws {
        cache.store(key: "refresh", payload: LyricPayload(lrc: "x", translation: nil))
        settle()
        let old = Date().addingTimeInterval(-10 * 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: files()[0].path)
        _ = load("refresh")
        let after = try files()[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        XCTAssertGreaterThan(after, old.addingTimeInterval(86400))
    }

    func testPurgeExpiredRemovesOnlyOldFiles() throws {
        cache.store(key: "a", payload: LyricPayload(lrc: "x", translation: nil))
        cache.store(key: "b", payload: LyricPayload(lrc: "y", translation: nil))
        settle()
        let victim = files()[0]
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-20 * 86400)], ofItemAtPath: victim.path)
        cache.purgeExpired(days: 14)
        settle()
        XCTAssertEqual(files().count, 1)
        XCTAssertFalse(files().contains(victim))
    }

    func testTrimKeepsAtMost800() {
        for i in 0..<805 { cache.store(key: "k\(i)", payload: LyricPayload(lrc: "x", translation: nil)) }
        settle()
        XCTAssertEqual(cache.count(), 800)
    }

    func testClearRemovesEverything() {
        cache.store(key: "a", payload: LyricPayload(lrc: "x", translation: nil))
        settle()
        cache.clear()
        XCTAssertEqual(cache.count(), 0)
    }
}
