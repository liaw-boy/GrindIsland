import XCTest
@testable import GrindIsland

final class ShelfStoreTests: XCTestCase {
    var dir: URL!
    var defaults: UserDefaults!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "shelf-test-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String) -> URL {
        let u = dir.appendingPathComponent(name); try? Data("x".utf8).write(to: u); return u
    }

    func testAddKeepsOnlyExistingFilesNewestFirstWithoutDuplicates() {
        let s = ShelfStore(defaults: defaults)
        let a = file("a.txt"), b = file("b.txt")
        s.add([a, URL(string: "https://example.com/x")!, dir.appendingPathComponent("missing.txt")])
        s.add([b, a])
        XCTAssertEqual(s.items.map(\.name), ["b.txt", "a.txt"])
        XCTAssertEqual(ShelfStore(defaults: defaults).items.count, 2, "persisted")
    }

    func testOldOrDeletedFilesArePruned() {
        let a = file("a.txt"), b = file("b.txt")
        let now = Date()
        let items = [ShelfStore.Item(path: a.path, added: now.addingTimeInterval(-25 * 3600)),
                     ShelfStore.Item(path: b.path, added: now)]
        try? FileManager.default.removeItem(at: b)
        XCTAssertTrue(ShelfStore.pruned(items, now: now).isEmpty)
    }
}

final class TaildropTests: XCTestCase {
    func testParsesTargetsAndRejectsUnsafeOnes() {
        let out = "100.64.0.2\tdemo-laptop\tmacOS\n100.64.0.3\tdemo-phone\n--evil\tx\nbad line\n100.64.0.4;rm\tx\n"
        XCTAssertEqual(Taildrop.parseTargets(out).map(\.name), ["demo-laptop", "demo-phone"])
        XCTAssertTrue(Taildrop.isSafeTarget("fd7a:115c:a1e0::1"))
        XCTAssertFalse(Taildrop.isSafeTarget("a b"))
        XCTAssertFalse(Taildrop.isSafeTarget("-h"))
    }
}
