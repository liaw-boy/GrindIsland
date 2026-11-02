import XCTest
@testable import GrindIsland

final class BatteryMonitorTests: XCTestCase {
    typealias R = BatteryMonitor.Reading

    func testPluggingInIsAnnounced() {
        let n = BatteryMonitor.notice(from: R(percent: 55, onAC: false), to: R(percent: 55, onAC: true))
        XCTAssertEqual(n?.title, "充電中")
        XCTAssertEqual(n?.trailing, "55%")
        XCTAssertNil(BatteryMonitor.notice(from: R(percent: 55, onAC: true), to: R(percent: 56, onAC: true)))
        XCTAssertNil(BatteryMonitor.notice(from: nil, to: R(percent: 55, onAC: true)), "nothing at launch")
    }

    func testLowBatteryOnlyWhenCrossingAMark() {
        XCTAssertEqual(BatteryMonitor.notice(from: R(percent: 21, onAC: false), to: R(percent: 20, onAC: false))?.title, "電量低")
        XCTAssertNil(BatteryMonitor.notice(from: R(percent: 20, onAC: false), to: R(percent: 19, onAC: false)))
        XCTAssertEqual(BatteryMonitor.notice(from: R(percent: 11, onAC: false), to: R(percent: 10, onAC: false))?.tint, .red)
        XCTAssertNil(BatteryMonitor.notice(from: R(percent: 21, onAC: true), to: R(percent: 20, onAC: true)), "charging")
    }
}

final class VolumeNoticeTests: XCTestCase {
    func testIconAndLevel() {
        XCTAssertEqual(VolumeMonitor.notice(volume: 0.62, muted: false).meter, 0.62)
        XCTAssertEqual(VolumeMonitor.notice(volume: 0.62, muted: false).icon, "speaker.wave.3.fill", "one symbol; the level fills its waves")
        XCTAssertEqual(VolumeMonitor.notice(volume: 0.1, muted: false).icon, "speaker.wave.3.fill", "same width at every level")
        XCTAssertEqual(VolumeMonitor.notice(volume: 0.9, muted: true).icon, "speaker.slash.fill")
        XCTAssertEqual(VolumeMonitor.notice(volume: 0.9, muted: true).meter, 0)
    }
}

final class SystemMonitorTests: XCTestCase {
    func testCpuLoadFromTicks() {
        XCTAssertEqual(SystemMonitor.load(from: [0, 0, 0, 0], to: [30, 10, 60, 0]), 0.4, accuracy: 1e-9)
        XCTAssertEqual(SystemMonitor.load(from: [5, 5, 5, 5], to: [5, 5, 5, 5]), 0)
    }

    func testLiveReadingsAreSane() {
        XCTAssertNotNil(SystemMonitor.cpuTicks())
        let (used, total) = SystemMonitor.memory()
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(used, total)
    }
}

final class ByteFormatTests: XCTestCase {
    func testSplit() {
        XCTAssertEqual(SystemMonitor.split(0, perSecond: true).0, "0")
        XCTAssertEqual(SystemMonitor.split(0, perSecond: true).1, "B/s")
        XCTAssertEqual(SystemMonitor.split(15_300, perSecond: true).1, "KB/s")
        XCTAssertEqual(SystemMonitor.split(12.5 * 1_073_741_824).0, "12.5")
        XCTAssertEqual(SystemMonitor.split(12.5 * 1_073_741_824).1, "GB")
    }
}
