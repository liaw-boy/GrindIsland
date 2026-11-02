import CoreAudio
import XCTest
@testable import GrindIsland

final class SystemEventsTests: XCTestCase {
    typealias Net = SystemEvents.Net

    func testNetworkOnlyAnnouncesDropAndReturn() {
        let wifi = Net(online: true, kind: "Wi-Fi"), off = Net(online: false, kind: "其他網路")
        XCTAssertNil(SystemEvents.netNotice(from: nil, to: wifi), "nothing at launch")
        XCTAssertEqual(SystemEvents.netNotice(from: wifi, to: off)?.trailing, "離線")
        XCTAssertEqual(SystemEvents.netNotice(from: off, to: wifi)?.icon, "wifi")
        XCTAssertNil(SystemEvents.netNotice(from: wifi, to: Net(online: true, kind: "其他網路")), "VPN / interface switch")
    }

    func testDisplays() {
        XCTAssertEqual(SystemEvents.displayNotice(old: ["Built-in"], new: ["Built-in", "Studio Display"])?.title, "已連接螢幕")
        XCTAssertEqual(SystemEvents.displayNotice(old: ["Built-in", "Studio Display"], new: ["Built-in"])?.detail, "Studio Display")
        XCTAssertNil(SystemEvents.displayNotice(old: ["Built-in"], new: ["Built-in"]))
    }

    func testThermalOnlyWhenGettingWorse() {
        XCTAssertNotNil(SystemEvents.thermalNotice(from: .fair, to: .serious))
        XCTAssertEqual(SystemEvents.thermalNotice(from: .serious, to: .critical)?.tint, .red)
        XCTAssertNil(SystemEvents.thermalNotice(from: .nominal, to: .fair))
        XCTAssertNil(SystemEvents.thermalNotice(from: .critical, to: .serious))
    }

    func testAudioDeviceNotice() {
        let pods = VolumeMonitor.deviceNotice(name: "Example AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
        XCTAssertEqual(pods.icon, "airpods.pro")
        XCTAssertEqual(pods.title, "已連線")
        XCTAssertEqual(VolumeMonitor.deviceNotice(name: "USB Headset", transport: kAudioDeviceTransportTypeUSB).icon, "headphones")
        XCTAssertEqual(VolumeMonitor.deviceNotice(name: "Speakers", transport: kAudioDeviceTransportTypeBuiltIn).trailing, "喇叭")
        XCTAssertEqual(VolumeMonitor.deviceNotice(name: String(repeating: "x", count: 99) + "\nmore", transport: 0).detail.count, 40)
    }

    func testEarbudBatteryFromBluetoothReport() throws {
        let json = """
        {"SPBluetoothDataType":[{"device_connected":[
          {"Example Speaker":{"device_minorType":"Speaker"}},
          {"Example AirPods":{"device_batteryLevelLeft":"98%","device_batteryLevelRight":"91%","device_batteryLevelCase":"84%"}}
        ]}]}
        """.data(using: .utf8)!
        let b = try XCTUnwrap(VolumeMonitor.budBattery(json: json, name: "Example AirPods"))
        XCTAssertEqual(b.buds, 91, "the lower earbud")
        XCTAssertEqual(b.case_, 84)
        XCTAssertEqual(VolumeMonitor.budBattery(json: json, name: "Renamed Pods")?.buds, 91, "only one device has levels")
        XCTAssertNil(VolumeMonitor.budBattery(json: Data("not json".utf8), name: "x"))
        let n = VolumeMonitor.deviceNotice(name: "Example AirPods", transport: kAudioDeviceTransportTypeBluetooth, battery: b)
        XCTAssertEqual(n.trailing, "91%")
        XCTAssertEqual(n.detail, "Example AirPods · 耳機 91% · 盒 84%")
        XCTAssertEqual(n.earbuds?.buds, 91)
        XCTAssertEqual(n.earbuds?.caseLevel, 84)
        let bad = #"{"SPBluetoothDataType":[{"device_connected":[{"P":{"device_batteryLevelLeft":"250%"}}]}]}"#
        XCTAssertNil(VolumeMonitor.budBattery(json: Data(bad.utf8), name: "P"), "out of range")
        let keyboard = #"{"SPBluetoothDataType":[{"device_connected":[{"Example Keyboard":{"device_batteryLevelMain":"55%"}}]}]}"#
        XCTAssertNil(VolumeMonitor.budBattery(json: Data(keyboard.utf8), name: "Other Pods"), "never a keyboard's battery")
        let curly = #"{"SPBluetoothDataType":[{"device_connected":[{"Demo’s AirPods":{"device_batteryLevelLeft":"70%"}},{"Demo2":{"device_batteryLevelLeft":"10%"}}]}]}"#
        XCTAssertEqual(VolumeMonitor.budBattery(json: Data(curly.utf8), name: "Demo's AirPods")?.buds, 70, "quote styles match")
    }

    func testBrightnessOnlyForUserChanges() {
        XCTAssertTrue(BrightnessMonitor.isUserChange(old: 0.5, new: 0.5625, secondsSinceInput: 0.1), "a key step")
        XCTAssertFalse(BrightnessMonitor.isUserChange(old: 0.5, new: 0.505, secondsSinceInput: 0.1), "auto-brightness drift")
        XCTAssertFalse(BrightnessMonitor.isUserChange(old: 1, new: 0, secondsSinceInput: 30), "backlight idle fade")
        let n = BrightnessMonitor.notice(level: 0.625, keyboard: false)
        XCTAssertEqual(n.trailing, "63")
        XCTAssertEqual(n.meter, 0.63)
        XCTAssertEqual(BrightnessMonitor.notice(level: 1, keyboard: true).title, "鍵盤亮度")
    }

    func testGPUStatistics() {
        let g = SystemMonitor.gpu(from: ["Device Utilization %": 37, "In use system memory": 600_000_000])
        XCTAssertEqual(g?.utilization ?? 0, 0.37, accuracy: 0.0001)
        XCTAssertEqual(g?.memory, 600_000_000)
        XCTAssertNil(SystemMonitor.gpu(from: ["Renderer Utilization %": 5]))
        XCTAssertNil(SystemMonitor.gpu(from: ["Device Utilization %": 250]))
    }

    func testEarbudModelFromProductID() {
        let json = #"{"SPBluetoothDataType":[{"device_connected":[{"Demo Buds":{"device_productID":"0x2013","device_batteryLevelLeft":"80%","device_batteryLevelRight":"90%","device_batteryLevelCase":"50%"}}]}]}"#
        let b = VolumeMonitor.budBattery(json: Data(json.utf8), name: "Demo Buds")
        XCTAssertEqual(b?.productID, 0x2013)
        let n = VolumeMonitor.deviceNotice(name: "Demo Buds", transport: kAudioDeviceTransportTypeBluetooth, battery: b)
        XCTAssertEqual(n.icon, "airpods.gen3", "the model, though the name says nothing")
        XCTAssertEqual(n.earbuds?.caseIcon, "airpods.gen3.chargingcase.wireless.fill")
        XCTAssertNil(VolumeMonitor.model(productID: 0x1234))
        let noCharge = #"{"SPBluetoothDataType":[{"device_connected":[{"Demo’s Buds":{"device_productID":"0x2013"}}]}]}"#
        XCTAssertEqual(VolumeMonitor.productID(json: Data(noCharge.utf8), name: "Demo's Buds"), 0x2013, "model before any charge is reported")
        XCTAssertNil(VolumeMonitor.productID(json: Data(noCharge.utf8), name: "Other"))
        XCTAssertEqual(VolumeMonitor.symbol("no.such.symbol.x", else: "headphones"), "headphones")
    }
}

final class SingleEarbudTests: XCTestCase {
    func testOneEarbudOutSaysWhichSide() {
        let b = VolumeMonitor.BudBattery(left: 80, right: nil, case_: 60, productID: 0x2013)
        let n = VolumeMonitor.deviceNotice(name: "Demo Buds", transport: kAudioDeviceTransportTypeBluetooth, battery: b)
        XCTAssertEqual(n.detail, "Demo Buds · 左耳 80% · 盒 60%")
        XCTAssertEqual(n.icon, "airpod.gen3.left")
        XCTAssertEqual(VolumeMonitor.singleIcon("airpods.pro", side: "right"), "airpodpro.right")
        XCTAssertEqual(VolumeMonitor.singleIcon("airpods", side: "left"), "airpod.left")
        let both = VolumeMonitor.deviceNotice(name: "Demo Buds", transport: kAudioDeviceTransportTypeBluetooth,
                                              battery: .init(left: 80, right: 70, productID: 0x2013))
        XCTAssertEqual(both.icon, "airpods.gen3")
        XCTAssertTrue(both.detail.contains("耳機 70%"))
    }
}
