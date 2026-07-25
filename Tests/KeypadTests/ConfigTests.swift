/**
 Unit tests for Keypad configuration loading, validation, and TOML serialization.
 */

import XCTest
@testable import Keypad

final class ConfigTests: XCTestCase {
    private var tempFolderURL: URL!

    override func setUp() {
        super.setUp()
        tempFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempFolderURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFolderURL)
        super.tearDown()
    }

    private func createTempFile(name: String, content: String) -> String {
        let fileURL = tempFolderURL.appendingPathComponent(name)
        try! content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL.path
    }

    // MARK: - Valid Config & Every Action Type Test

    func testEveryActionTypeParses() throws {
        let tomlContent = """
        [device]
        vendor_id = 0x1234
        product_id = 0x5678
        usage_page = 0xff00
        usage = 0x0001
        protocol = "keyboard"

        [layout]
        rows = 4
        cols = 4
        knobs = 2

        [app]
        statusbar = true
        log_level = "DEBUG"
        icon = "/path/to/icon.png"
        launch_at_login = true

        [[key]]
        row = 0
        col = 0
        action = { type = "macro", keys = ["cmd+c", "cmd+v"] }

        [[key]]
        row = 0
        col = 1
        action = { type = "media", control = "play_pause" }

        [[key]]
        row = 0
        col = 2
        action = { type = "app", name = "Safari", path = "/Applications/Safari.app" }

        [[key]]
        row = 0
        col = 3
        action = { type = "script", path = "/usr/bin/python3", args = ["-c", "print(1)"] }

        [[key]]
        row = 1
        col = 0
        action = { type = "shell", command = "echo test" }

        [[key]]
        row = 1
        col = 1
        action = { type = "aerospace", command = "workspace 3" }

        [[key]]
        row = 1
        col = 2
        action = { type = "url", url = "https://apple.com" }

        [[key]]
        row = 1
        col = 3
        action = { type = "text", text = "hello world" }

        [[key]]
        row = 2
        col = 0
        action = { type = "applescript", source = "beep" }

        [[key]]
        row = 2
        col = 1
        action = { type = "shortcut", name = "MyShortcut" }

        [[key]]
        row = 2
        col = 2
        action = { type = "system", command = "lock_screen" }

        [[key]]
        row = 2
        col = 3
        action = { type = "volume", level = 75 }

        [[key]]
        row = 3
        col = 0
        action = { type = "notification", text = "Message", title = "Title" }

        [[key]]
        row = 3
        col = 1
        action = { type = "sequence", steps = [{ type = "app", name = "Safari" }, { type = "macro", keys = "cmd+v" }], delay = 0.5 }

        [[knob]]
        index = 0
        on_cw = { type = "media", control = "volume_up" }
        on_ccw = { type = "media", control = "volume_down" }
        on_press = { type = "media", control = "mute" }
        """

        let path = createTempFile(name: "all_actions.toml", content: tomlContent)
        let config = try loadConfig(atPath: path)

        XCTAssertEqual(config.device.vendorID, 0x1234)
        XCTAssertEqual(config.device.productID, 0x5678)
        XCTAssertEqual(config.device.usagePage, 0xff00)
        XCTAssertEqual(config.device.usage, 0x0001)
        XCTAssertEqual(config.device.protocolName, "keyboard")

        XCTAssertEqual(config.layout.rows, 4)
        XCTAssertEqual(config.layout.cols, 4)
        XCTAssertEqual(config.layout.knobs, 2)

        XCTAssertEqual(config.statusbar, true)
        XCTAssertEqual(config.logLevel, "DEBUG")
        XCTAssertEqual(config.icon, "/path/to/icon.png")
        XCTAssertEqual(config.launchAtLogin, true)

        XCTAssertEqual(config.keys.count, 14)
        XCTAssertEqual(config.knobs.count, 1)

        // Verify sequence action step parsing
        let seqKey = config.keys.first { $0.row == 3 && $0.col == 1 }
        XCTAssertNotNil(seqKey)
        XCTAssertEqual(seqKey?.action.type, "sequence")
        XCTAssertEqual(seqKey?.action.steps.count, 2)
        XCTAssertEqual(seqKey?.action.delay, 0.5)
    }

    // MARK: - Invalid Config Assertions

    func testInvalidActionTypeThrows() {
        let content = """
        [device]
        vendor_id = 1
        product_id = 2

        [layout]
        rows = 1
        cols = 1
        knobs = 0

        [[key]]
        row = 0
        col = 0
        action = { type = "unknown_action_type" }
        """
        let path = createTempFile(name: "invalid_action.toml", content: content)
        XCTAssertThrowsError(try loadConfig(atPath: path)) { error in
            guard case ConfigError.invalid(let msg) = error else {
                return XCTFail("Expected ConfigError.invalid")
            }
            XCTAssertTrue(msg.contains("Unsupported action type"))
        }
    }

    func testRowOutOfRangeThrows() {
        let content = """
        [device]
        vendor_id = 1
        product_id = 2

        [layout]
        rows = 2
        cols = 2
        knobs = 0

        [[key]]
        row = 2
        col = 0
        action = { type = "shell", command = "ls" }
        """
        let path = createTempFile(name: "out_of_range.toml", content: content)
        XCTAssertThrowsError(try loadConfig(atPath: path)) { error in
            guard case ConfigError.invalid(let msg) = error else {
                return XCTFail("Expected ConfigError.invalid")
            }
            XCTAssertTrue(msg.contains("out of range"))
        }
    }

    func testDuplicateKeyBindingThrows() {
        let content = """
        [device]
        vendor_id = 1
        product_id = 2

        [layout]
        rows = 2
        cols = 2
        knobs = 0

        [[key]]
        row = 0
        col = 0
        action = { type = "shell", command = "ls" }

        [[key]]
        row = 0
        col = 0
        action = { type = "shell", command = "pwd" }
        """
        let path = createTempFile(name: "duplicate_key.toml", content: content)
        XCTAssertThrowsError(try loadConfig(atPath: path)) { error in
            guard case ConfigError.invalid(let msg) = error else {
                return XCTFail("Expected ConfigError.invalid")
            }
            XCTAssertTrue(msg.contains("Duplicate key binding"))
        }
    }

    func testNestedSequenceThrows() {
        let content = """
        [device]
        vendor_id = 1
        product_id = 2

        [layout]
        rows = 1
        cols = 1
        knobs = 0

        [[key]]
        row = 0
        col = 0
        action = { type = "sequence", steps = [{ type = "sequence", steps = [{ type = "shell", command = "ls" }] }] }
        """
        let path = createTempFile(name: "nested_seq.toml", content: content)
        XCTAssertThrowsError(try loadConfig(atPath: path)) { error in
            guard case ConfigError.invalid(let msg) = error else {
                return XCTFail("Expected ConfigError.invalid")
            }
            XCTAssertTrue(msg.contains("cannot be nested"))
        }
    }

    func testVolumeLevelOutOfRangeThrows() {
        let content = """
        [device]
        vendor_id = 1
        product_id = 2

        [layout]
        rows = 1
        cols = 1
        knobs = 0

        [[key]]
        row = 0
        col = 0
        action = { type = "volume", level = 150 }
        """
        let path = createTempFile(name: "bad_volume.toml", content: content)
        XCTAssertThrowsError(try loadConfig(atPath: path)) { error in
            guard case ConfigError.invalid(let msg) = error else {
                return XCTFail("Expected ConfigError.invalid")
            }
            XCTAssertTrue(msg.contains("level"))
        }
    }

    func testLaunchAtLoginNonBoolThrows() {
        let content = """
        [device]
        vendor_id = 1
        product_id = 2

        [layout]
        rows = 1
        cols = 1
        knobs = 0

        [app]
        launch_at_login = "yes"
        """
        let path = createTempFile(name: "bad_login.toml", content: content)
        XCTAssertThrowsError(try loadConfig(atPath: path)) { error in
            guard case ConfigError.invalid(let msg) = error else {
                return XCTFail("Expected ConfigError.invalid")
            }
            XCTAssertTrue(msg.contains("launch_at_login"))
        }
    }

    // MARK: - dumpsTOML Round-Trip Test

    func testDumpsTOMLRoundTrip() throws {
        let device = DeviceConfig(vendorID: 0x1234, productID: 0x5678, usagePage: 0xff00, usage: 0x0001, protocolName: "keyboard")
        let layout = LayoutConfig(rows: 2, cols: 2, knobs: 1)
        let app = AppDump(statusbar: true, logLevel: "DEBUG", icon: "/path/to/icon.png", launchAtLogin: true)

        let keys: [(row: Int, col: Int, action: KeypadAction?)] = [
            (0, 0, KeypadAction(type: "macro", keys: ["cmd+c"])),
            (0, 1, KeypadAction(type: "media", control: "play_pause")),
            (1, 0, KeypadAction(type: "shell", command: "echo test"))
        ]

        let knobs: [(index: Int, onCW: KeypadAction?, onCCW: KeypadAction?, onPress: KeypadAction?)] = [
            (0, KeypadAction(type: "media", control: "volume_up"), KeypadAction(type: "media", control: "volume_down"), KeypadAction(type: "media", control: "mute"))
        ]

        let dumpModel = ConfigDump(device: device, layout: layout, app: app, keys: keys, knobs: knobs)

        let tomlString = dumpsTOML(dumpModel)
        let path = createTempFile(name: "dump_roundtrip.toml", content: tomlString)

        let loaded = try loadConfig(atPath: path)

        XCTAssertEqual(loaded.device.vendorID, 0x1234)
        XCTAssertEqual(loaded.device.productID, 0x5678)
        XCTAssertEqual(loaded.device.usagePage, 0xff00)
        XCTAssertEqual(loaded.device.usage, 0x0001)
        XCTAssertEqual(loaded.device.protocolName, "keyboard")

        XCTAssertEqual(loaded.layout.rows, 2)
        XCTAssertEqual(loaded.layout.cols, 2)
        XCTAssertEqual(loaded.layout.knobs, 1)

        XCTAssertEqual(loaded.statusbar, true)
        XCTAssertEqual(loaded.logLevel, "DEBUG")
        XCTAssertEqual(loaded.icon, "/path/to/icon.png")
        XCTAssertEqual(loaded.launchAtLogin, true)

        XCTAssertEqual(loaded.keys.count, 3)
        XCTAssertEqual(loaded.knobs.count, 1)

        XCTAssertEqual(loaded.keys[0].action, KeypadAction(type: "macro", keys: ["cmd+c"]))
        XCTAssertEqual(loaded.keys[1].action, KeypadAction(type: "media", control: "play_pause"))
        XCTAssertEqual(loaded.keys[2].action, KeypadAction(type: "shell", command: "echo test"))

        XCTAssertEqual(loaded.knobs[0].onCW, KeypadAction(type: "media", control: "volume_up"))
        XCTAssertEqual(loaded.knobs[0].onCCW, KeypadAction(type: "media", control: "volume_down"))
        XCTAssertEqual(loaded.knobs[0].onPress, KeypadAction(type: "media", control: "mute"))
    }

    // MARK: - Multi-Device Tests

    func testMultipleDeviceBlocksParse() throws {
        let content = """
        [[device]]
        vendor_id = 0x07d7
        product_id = 0x0000
        usage_page = 0x0001
        usage = 0x0006
        protocol = "keyboard"

        [[device]]
        vendor_id = 0x1189
        product_id = 0x8890
        usage_page = 0x0001
        usage = 0x0006
        protocol = "keyboard"

        [layout]
        rows = 3
        cols = 4
        knobs = 2
        """
        let path = createTempFile(name: "multi_device.toml", content: content)
        let config = try loadConfig(atPath: path)

        XCTAssertEqual(config.devices.count, 2)
        XCTAssertEqual(config.devices[0].vendorID, 0x07d7)
        XCTAssertEqual(config.devices[0].productID, 0x0000)
        XCTAssertEqual(config.devices[1].vendorID, 0x1189)
        XCTAssertEqual(config.devices[1].productID, 0x8890)
        XCTAssertEqual(config.devices[1].protocolName, "keyboard")
        // Primary device stays the first entry for legacy callers.
        XCTAssertEqual(config.device.vendorID, 0x07d7)
    }

    func testSingleDeviceTableStillParses() throws {
        let content = """
        [device]
        vendor_id = 0x1234
        product_id = 0x5678

        [layout]
        rows = 3
        cols = 3
        knobs = 0
        """
        let path = createTempFile(name: "single_device.toml", content: content)
        let config = try loadConfig(atPath: path)

        XCTAssertEqual(config.devices.count, 1)
        XCTAssertEqual(config.device.vendorID, 0x1234)
        XCTAssertEqual(config.device.protocolName, "vendor")
    }

    func testInvalidDeviceEntryInArrayThrows() throws {
        let content = """
        [[device]]
        vendor_id = 0x1234
        product_id = 0x5678

        [[device]]
        vendor_id = 0x9999

        [layout]
        rows = 3
        cols = 3
        knobs = 0
        """
        let path = createTempFile(name: "bad_multi_device.toml", content: content)
        XCTAssertThrowsError(try loadConfig(atPath: path)) { error in
            guard case ConfigError.invalid(let msg) = error else {
                return XCTFail("Expected ConfigError.invalid")
            }
            XCTAssertTrue(msg.contains("product_id"))
        }
    }

    func testDumpsTOMLMultiDeviceRoundTrip() throws {
        let devices = [
            DeviceConfig(vendorID: 0x07d7, productID: 0x0000, usagePage: 0x0001, usage: 0x0006, protocolName: "keyboard"),
            DeviceConfig(vendorID: 0x1189, productID: 0x8890, usagePage: 0x0001, usage: 0x0006, protocolName: "keyboard")
        ]
        let layout = LayoutConfig(rows: 3, cols: 4, knobs: 2)
        let app = AppDump(statusbar: false, logLevel: "INFO", icon: nil, launchAtLogin: true)

        let dumpModel = ConfigDump(devices: devices, layout: layout, app: app)
        let tomlString = dumpsTOML(dumpModel)
        let path = createTempFile(name: "dump_multi_roundtrip.toml", content: tomlString)

        let loaded = try loadConfig(atPath: path)

        XCTAssertEqual(loaded.devices, devices)
        XCTAssertEqual(loaded.layout, layout)
    }
}
