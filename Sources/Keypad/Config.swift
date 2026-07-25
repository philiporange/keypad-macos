/**
 Configuration loader and validator for macro keypad bindings using TOML format.
 */

import Foundation
import TOMLKit

// MARK: - Constants

public let validMediaControls: Set<String> = [
    "play_pause",
    "next",
    "previous",
    "volume_up",
    "volume_down",
    "mute",
    "brightness_up",
    "brightness_down"
]

public let validActionTypes: Set<String> = [
    "macro",
    "media",
    "app",
    "script",
    "shell",
    "aerospace",
    "url",
    "text",
    "applescript",
    "shortcut",
    "system",
    "volume",
    "notification",
    "sequence"
]

public let validSystemCommands: Set<String> = [
    "lock_screen",
    "display_sleep",
    "system_sleep",
    "screensaver",
    "mission_control",
    "launchpad",
    "show_desktop",
    "toggle_dark_mode"
]

public let validProtocols: Set<String> = [
    "vendor",
    "keyboard"
]

// MARK: - Error Types

public enum ConfigError: Error, CustomStringConvertible, Equatable {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

// MARK: - Models

public struct KeypadAction: Equatable {
    public var type: String
    public var keys: [String]?
    public var control: String?
    public var name: String?
    public var path: String?
    public var args: [String]
    public var command: String?
    public var url: String?
    public var text: String?
    public var source: String?
    public var title: String?
    public var level: Int?
    public var steps: [KeypadAction]
    public var delay: Double

    public init(
        type: String,
        keys: [String]? = nil,
        control: String? = nil,
        name: String? = nil,
        path: String? = nil,
        args: [String] = [],
        command: String? = nil,
        url: String? = nil,
        text: String? = nil,
        source: String? = nil,
        title: String? = nil,
        level: Int? = nil,
        steps: [KeypadAction] = [],
        delay: Double = 0.0
    ) {
        self.type = type
        self.keys = keys
        self.control = control
        self.name = name
        self.path = path
        self.args = args
        self.command = command
        self.url = url
        self.text = text
        self.source = source
        self.title = title
        self.level = level
        self.steps = steps
        self.delay = delay
    }
}

public struct DeviceConfig: Equatable {
    public var vendorID: Int
    public var productID: Int
    public var usagePage: Int?
    public var usage: Int?
    public var protocolName: String

    public init(
        vendorID: Int,
        productID: Int,
        usagePage: Int? = nil,
        usage: Int? = nil,
        protocolName: String = "vendor"
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.usagePage = usagePage
        self.usage = usage
        self.protocolName = protocolName
    }
}

public struct LayoutConfig: Equatable {
    public var rows: Int
    public var cols: Int
    public var knobs: Int

    public init(rows: Int, cols: Int, knobs: Int) {
        self.rows = rows
        self.cols = cols
        self.knobs = knobs
    }
}

public struct KeyBinding: Equatable {
    public var row: Int
    public var col: Int
    public var action: KeypadAction

    public init(row: Int, col: Int, action: KeypadAction) {
        self.row = row
        self.col = col
        self.action = action
    }
}

public struct KnobBinding: Equatable {
    public var index: Int
    public var onCW: KeypadAction?
    public var onCCW: KeypadAction?
    public var onPress: KeypadAction?

    public init(index: Int, onCW: KeypadAction? = nil, onCCW: KeypadAction? = nil, onPress: KeypadAction? = nil) {
        self.index = index
        self.onCW = onCW
        self.onCCW = onCCW
        self.onPress = onPress
    }
}

public struct Config: Equatable {
    /// All configured device identities. The daemon listens to every entry,
    /// so a pad reachable both wired (USB) and wireless (dongle/Bluetooth,
    /// different VID/PID) works from a single config. Always non-empty.
    public var devices: [DeviceConfig]
    public var layout: LayoutConfig
    public var keys: [KeyBinding]
    public var knobs: [KnobBinding]
    public var statusbar: Bool
    public var logLevel: String
    public var icon: String?
    public var launchAtLogin: Bool

    /// The primary (first) device, for callers that predate multi-device.
    public var device: DeviceConfig { devices[0] }

    public init(
        devices: [DeviceConfig],
        layout: LayoutConfig,
        keys: [KeyBinding] = [],
        knobs: [KnobBinding] = [],
        statusbar: Bool = true,
        logLevel: String = "INFO",
        icon: String? = nil,
        launchAtLogin: Bool = false
    ) {
        self.devices = devices
        self.layout = layout
        self.keys = keys
        self.knobs = knobs
        self.statusbar = statusbar
        self.logLevel = logLevel
        self.icon = icon
        self.launchAtLogin = launchAtLogin
    }

    public init(
        device: DeviceConfig,
        layout: LayoutConfig,
        keys: [KeyBinding] = [],
        knobs: [KnobBinding] = [],
        statusbar: Bool = true,
        logLevel: String = "INFO",
        icon: String? = nil,
        launchAtLogin: Bool = false
    ) {
        self.init(
            devices: [device],
            layout: layout,
            keys: keys,
            knobs: knobs,
            statusbar: statusbar,
            logLevel: logLevel,
            icon: icon,
            launchAtLogin: launchAtLogin
        )
    }
}

// MARK: - Action Parsing Helper

func parseAction(_ table: TOMLTable) throws -> KeypadAction {
    guard let actionType = table["type"]?.string, !actionType.isEmpty else {
        throw ConfigError.invalid("Invalid or missing action type")
    }

    guard validActionTypes.contains(actionType) else {
        throw ConfigError.invalid("Unsupported action type: \(actionType)")
    }

    switch actionType {
    case "macro":
        if let keysStr = table["keys"]?.string {
            return KeypadAction(type: "macro", keys: [keysStr])
        } else if let keysArray = table["keys"]?.array?.compactMap({ $0.string }) {
            guard !keysArray.isEmpty else {
                throw ConfigError.invalid("Macro action requires 'keys' string or list of strings")
            }
            return KeypadAction(type: "macro", keys: keysArray)
        }
        throw ConfigError.invalid("Macro action requires 'keys' string or list of strings")

    case "media":
        guard let control = table["control"]?.string, validMediaControls.contains(control) else {
            let ctrlStr = table["control"]?.string ?? "nil"
            throw ConfigError.invalid("Media action requires valid 'control', got \(ctrlStr)")
        }
        return KeypadAction(type: "media", control: control)

    case "app":
        let name = table["name"]?.string
        let path = table["path"]?.string
        guard name != nil || path != nil else {
            throw ConfigError.invalid("App action requires 'name' or 'path'")
        }
        return KeypadAction(type: "app", name: name, path: path)

    case "script":
        guard let path = table["path"]?.string, !path.isEmpty else {
            throw ConfigError.invalid("Script action requires string 'path'")
        }
        let args = table["args"]?.array?.compactMap { $0.string } ?? []
        return KeypadAction(type: "script", path: path, args: args)

    case "shell":
        guard let command = table["command"]?.string, !command.isEmpty else {
            throw ConfigError.invalid("Shell action requires string 'command'")
        }
        return KeypadAction(type: "shell", command: command)

    case "aerospace":
        guard let command = table["command"]?.string, !command.isEmpty else {
            throw ConfigError.invalid("Aerospace action requires string 'command' (e.g. 'workspace 3')")
        }
        return KeypadAction(type: "aerospace", command: command)

    case "url":
        guard let url = table["url"]?.string, !url.isEmpty else {
            throw ConfigError.invalid("URL action requires string 'url'")
        }
        return KeypadAction(type: "url", url: url)

    case "text":
        guard let text = table["text"]?.string, !text.isEmpty else {
            throw ConfigError.invalid("Text action requires string 'text'")
        }
        return KeypadAction(type: "text", text: text)

    case "applescript":
        guard let source = table["source"]?.string, !source.isEmpty else {
            throw ConfigError.invalid("AppleScript action requires string 'source'")
        }
        return KeypadAction(type: "applescript", source: source)

    case "shortcut":
        guard let name = table["name"]?.string, !name.isEmpty else {
            throw ConfigError.invalid("Shortcut action requires string 'name' (the Shortcuts shortcut name)")
        }
        return KeypadAction(type: "shortcut", name: name)

    case "system":
        guard let command = table["command"]?.string, validSystemCommands.contains(command) else {
            let cmdStr = table["command"]?.string ?? "nil"
            let sortedCmds = validSystemCommands.sorted()
            throw ConfigError.invalid("System action requires 'command' from \(sortedCmds), got \(cmdStr)")
        }
        return KeypadAction(type: "system", command: command)

    case "volume":
        guard let level = table["level"]?.int, (0...100).contains(level) else {
            let lvlStr = table["level"]?.int.map { String($0) } ?? "nil"
            throw ConfigError.invalid("Volume action requires integer 'level' 0-100, got \(lvlStr)")
        }
        return KeypadAction(type: "volume", level: level)

    case "notification":
        guard let text = table["text"]?.string, !text.isEmpty else {
            throw ConfigError.invalid("Notification action requires string 'text'")
        }
        let title = table["title"]?.string
        return KeypadAction(type: "notification", text: text, title: title)

    case "sequence":
        guard let stepsArray = table["steps"]?.array, !stepsArray.isEmpty else {
            throw ConfigError.invalid("Sequence action requires non-empty 'steps' list of actions")
        }
        var steps: [KeypadAction] = []
        for stepItem in stepsArray {
            guard let stepTable = stepItem.table else {
                throw ConfigError.invalid("Sequence step must be an action table")
            }
            let stepAction = try parseAction(stepTable)
            if stepAction.type == "sequence" {
                throw ConfigError.invalid("Sequence actions cannot be nested")
            }
            steps.append(stepAction)
        }
        let delay: Double
        if let d = table["delay"]?.double {
            delay = d
        } else if let dInt = table["delay"]?.int {
            delay = Double(dInt)
        } else if table["delay"] == nil {
            delay = 0.0
        } else {
            throw ConfigError.invalid("Sequence 'delay' must be a non-negative number of seconds")
        }
        guard delay >= 0 else {
            throw ConfigError.invalid("Sequence 'delay' must be a non-negative number of seconds")
        }
        return KeypadAction(type: "sequence", steps: steps, delay: delay)

    default:
        throw ConfigError.invalid("Unsupported action type: \(actionType)")
    }
}

// MARK: - Config Loader

public func loadConfig(atPath path: String) throws -> Config {
    let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        throw ConfigError.invalid("Configuration file not found: \(fileURL.path)")
    }

    let content: String
    do {
        content = try String(contentsOf: fileURL, encoding: .utf8)
    } catch {
        throw ConfigError.invalid("Error reading configuration file: \(error)")
    }

    let rootTable: TOMLTable
    do {
        rootTable = try TOMLTable(string: content)
    } catch {
        throw ConfigError.invalid("Error parsing TOML configuration: \(error)")
    }

    // Validate [device] (single table) or [[device]] (array of tables).
    // A pad that connects both wired and via a wireless dongle presents two
    // different VID/PID identities; listing both keeps it working either way.
    func parseDeviceTable(_ deviceTable: TOMLTable) throws -> DeviceConfig {
        guard let vendorID = deviceTable["vendor_id"]?.int else {
            throw ConfigError.invalid("Device vendor_id must be an integer")
        }

        guard let productID = deviceTable["product_id"]?.int else {
            throw ConfigError.invalid("Device product_id must be an integer")
        }

        let usagePage = deviceTable["usage_page"]?.int
        let usage = deviceTable["usage"]?.int

        let protocolName = deviceTable["protocol"]?.string ?? "vendor"
        guard validProtocols.contains(protocolName) else {
            let sortedProtocols = validProtocols.sorted()
            throw ConfigError.invalid("Device protocol must be one of \(sortedProtocols), got \(protocolName)")
        }

        return DeviceConfig(
            vendorID: vendorID,
            productID: productID,
            usagePage: usagePage,
            usage: usage,
            protocolName: protocolName
        )
    }

    var deviceConfigs: [DeviceConfig] = []
    if let deviceArray = rootTable["device"]?.array {
        for deviceItem in deviceArray {
            guard let deviceTable = deviceItem.table else {
                throw ConfigError.invalid("Each [[device]] entry must be a table")
            }
            deviceConfigs.append(try parseDeviceTable(deviceTable))
        }
        guard !deviceConfigs.isEmpty else {
            throw ConfigError.invalid("At least one [[device]] entry is required")
        }
    } else if let deviceTable = rootTable["device"]?.table {
        deviceConfigs.append(try parseDeviceTable(deviceTable))
    } else {
        throw ConfigError.invalid("Missing or invalid [device] section")
    }

    // Validate [layout]
    guard let layoutTable = rootTable["layout"]?.table else {
        throw ConfigError.invalid("Missing or invalid [layout] section")
    }

    guard let rows = layoutTable["rows"]?.int, rows > 0 else {
        throw ConfigError.invalid("Layout rows must be a positive integer")
    }

    guard let cols = layoutTable["cols"]?.int, cols > 0 else {
        throw ConfigError.invalid("Layout cols must be a positive integer")
    }

    guard let knobs = layoutTable["knobs"]?.int, knobs >= 0 else {
        throw ConfigError.invalid("Layout knobs must be a non-negative integer")
    }

    let layoutConfig = LayoutConfig(rows: rows, cols: cols, knobs: knobs)

    // Validate [[key]]
    var keyBindings: [KeyBinding] = []
    var seenKeys = Set<String>()

    if let keyArray = rootTable["key"]?.array {
        for keyItem in keyArray {
            guard let keyTable = keyItem.table else {
                throw ConfigError.invalid("Key entry must be a table")
            }
            guard let r = keyTable["row"]?.int, r >= 0, r < rows else {
                let rStr = keyTable["row"]?.int.map { String($0) } ?? "nil"
                throw ConfigError.invalid("Key binding row \(rStr) out of range [0, \(rows - 1)]")
            }
            guard let c = keyTable["col"]?.int, c >= 0, c < cols else {
                let cStr = keyTable["col"]?.int.map { String($0) } ?? "nil"
                throw ConfigError.invalid("Key binding col \(cStr) out of range [0, \(cols - 1)]")
            }

            let keyKey = "\(r),\(c)"
            if seenKeys.contains(keyKey) {
                throw ConfigError.invalid("Duplicate key binding for row \(r), col \(c)")
            }
            seenKeys.insert(keyKey)

            guard let actionTable = keyTable["action"]?.table else {
                throw ConfigError.invalid("Key binding at (\(r), \(c)) missing action")
            }

            let action = try parseAction(actionTable)
            keyBindings.append(KeyBinding(row: r, col: c, action: action))
        }
    }

    // Validate [[knob]]
    var knobBindings: [KnobBinding] = []
    var seenKnobs = Set<Int>()

    if let knobArray = rootTable["knob"]?.array {
        for knobItem in knobArray {
            guard let knobTable = knobItem.table else {
                throw ConfigError.invalid("Knob entry must be a table")
            }

            guard let idx = knobTable["index"]?.int, idx >= 0, idx < knobs else {
                let idxStr = knobTable["index"]?.int.map { String($0) } ?? "nil"
                throw ConfigError.invalid("Knob index \(idxStr) out of range [0, \(knobs - 1)]")
            }

            if seenKnobs.contains(idx) {
                throw ConfigError.invalid("Duplicate knob binding for index \(idx)")
            }
            seenKnobs.insert(idx)

            let onCW = try knobTable["on_cw"]?.table.map { try parseAction($0) }
            let onCCW = try knobTable["on_ccw"]?.table.map { try parseAction($0) }
            let onPress = try knobTable["on_press"]?.table.map { try parseAction($0) }

            knobBindings.append(KnobBinding(index: idx, onCW: onCW, onCCW: onCCW, onPress: onPress))
        }
    }

    // Validate [app]
    let appTable = rootTable["app"]?.table
    let statusbar = appTable?["statusbar"]?.bool ?? true
    let logLevel = (appTable?["log_level"]?.string ?? "INFO").uppercased()
    let icon = appTable?["icon"]?.string

    let launchAtLogin: Bool
    if let lVal = appTable?["launch_at_login"]?.bool {
        launchAtLogin = lVal
    } else if appTable?["launch_at_login"] != nil {
        throw ConfigError.invalid("app.launch_at_login must be a boolean")
    } else {
        launchAtLogin = false
    }

    return Config(
        devices: deviceConfigs,
        layout: layoutConfig,
        keys: keyBindings,
        knobs: knobBindings,
        statusbar: statusbar,
        logLevel: logLevel,
        icon: icon,
        launchAtLogin: launchAtLogin
    )
}
