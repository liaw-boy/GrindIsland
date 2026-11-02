import XCTest
@testable import GrindIsland

final class CatLookTests: XCTestCase {
    func testStableIndexIsDeterministicAndInRange() {
        let a = CatLook.stableIndex(for: "sample-project", count: 16)
        XCTAssertEqual(a, CatLook.stableIndex(for: "sample-project", count: 16))
        XCTAssertTrue((0..<16).contains(a))
    }

    func testStableIndexHandlesZeroCount() {
        XCTAssertEqual(CatLook.stableIndex(for: "x", count: 0), 0)
    }

    func testCatalogNamesAreUnique() {
        XCTAssertEqual(Set(CatLook.all.map(\.name)).count, CatLook.all.count)
    }

    func testSameFolderKeepsSameLook() {
        let first = CatLook.assign([(id: "s1", seed: "/demo/alpha")])
        let again = CatLook.assign([(id: "other-id", seed: "/demo/alpha")])
        XCTAssertEqual(first["s1"], again["other-id"])
    }

    func testSessionsInSameFolderGetDifferentLooks() {
        let result = CatLook.assign([(id: "a", seed: "/demo/same"), (id: "b", seed: "/demo/same")])
        XCTAssertNotEqual(result["a"], result["b"])
    }

    func testManySessionsNeverCollideWhileLooksRemain() {
        let sessions = (0..<CatLook.all.count).map { (id: "s\($0)", seed: "/demo/p\($0 % 3)") }
        let result = CatLook.assign(sessions)
        XCTAssertEqual(Set(result.values.map(\.name)).count, CatLook.all.count)
    }
}
