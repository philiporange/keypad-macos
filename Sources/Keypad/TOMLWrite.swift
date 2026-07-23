/**
 TOML serialization for keypad configuration.
 */

import Foundation

// MARK: - Dump Models

public struct AppDump: Equatable {
    public var statusbar: Bool
    public var logLevel: String
    public var icon: String?
    public var launchAtLogin: Bool

    public init(
        statusbar: Bool = true,
        logLevel: String = "INFO",
        icon: String? = nil,
        launchAtLogin: Bool = false
    ) {
        self.statusbar = statusbar
        self.logLevel = logLevel
        self.icon = icon
        self.launchAtLogin = launchAtLogin
    }
}

public struct ConfigDump: Equatable {
    public var device: DeviceConfig
    public var layout: LayoutConfig
    public var app: AppDump
    public var keys: [(row: Int, col: Int, action: KeypadAction?)]
    public var knobs: [(index: Int, onCW: KeypadAction?, onCCW: KeypadAction?, onPress: KeypadAction?)]

    public init(
        device: DeviceConfig,
        layout: LayoutConfig,
        app: AppDump,
        keys: [(row: Int, col: Int, action: KeypadAction?)] = [],
        knobs: [(index: Int, onCW: KeypadAction?, onCCW: KeypadAction?, onPress: KeypadAction?)] = []
    ) {
        self.device = device
        self.layout = layout
        self.app = app
        self.keys = keys
        self.knobs = knobs
    }

    public static func == (lhs: ConfigDump, rhs: ConfigDump) -> Bool {
        guard lhs.device == rhs.device, lhs.layout == rhs.layout, lhs.app == rhs.app else { return false }
        guard lhs.keys.count == rhs.keys.count, lhs.knobs.count == rhs.knobs.count else { return false }
        for (l, r) in zip(lhs.keys, rhs.keys) {
            if l.row != r.row || l.col != r.col || l.action != r.action { return false }
        }
        for (l, r) in zip(lhs.knobs, rhs.knobs) {
            if l.index != r.index || l.onCW != r.onCW || l.onCCW != r.onCCW || l.onPress != r.onPress { return false }
        }
        return true
    }
}

// MARK: - TOML Writer

private func escapeString(_ s: String) -> String {
    // TOML basic string: JSONEncoder is close but escapes '/' (invalid in
    // TOML), so escape by hand.
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04X", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

public func actionToInlineTable(_ a: KeypadAction) -> String {
    var items: [String] = []
    items.append("type = \(escapeString(a.type))")

    if let keys = a.keys, !keys.isEmpty {
        if keys.count == 1 {
            items.append("keys = \(escapeString(keys[0]))")
        } else {
            let strArr = keys.map { escapeString($0) }.joined(separator: ", ")
            items.append("keys = [\(strArr)]")
        }
    }
    if let control = a.control, !control.isEmpty {
        items.append("control = \(escapeString(control))")
    }
    if let name = a.name, !name.isEmpty {
        items.append("name = \(escapeString(name))")
    }
    if let path = a.path, !path.isEmpty {
        items.append("path = \(escapeString(path))")
    }
    if !a.args.isEmpty {
        let argArr = a.args.map { escapeString($0) }.joined(separator: ", ")
        items.append("args = [\(argArr)]")
    }
    if let command = a.command, !command.isEmpty {
        items.append("command = \(escapeString(command))")
    }
    if let url = a.url, !url.isEmpty {
        items.append("url = \(escapeString(url))")
    }
    if let text = a.text, !text.isEmpty {
        items.append("text = \(escapeString(text))")
    }
    if let source = a.source, !source.isEmpty {
        items.append("source = \(escapeString(source))")
    }
    if let title = a.title, !title.isEmpty {
        items.append("title = \(escapeString(title))")
    }
    if let level = a.level {
        items.append("level = \(level)")
    }
    if !a.steps.isEmpty {
        let stepArr = a.steps.map { actionToInlineTable($0) }.joined(separator: ", ")
        items.append("steps = [\(stepArr)]")
    }
    if a.delay > 0.0 {
        items.append("delay = \(a.delay)")
    }

    return "{ \(items.joined(separator: ", ")) }"
}

public func dumpsTOML(_ model: ConfigDump) -> String {
    var lines: [String] = []

    // [device]
    lines.append("[device]")
    let hexVID = String(format: "0x%04x", model.device.vendorID)
    let hexPID = String(format: "0x%04x", model.device.productID)
    lines.append("vendor_id = \(hexVID)")
    lines.append("product_id = \(hexPID)")

    if let up = model.device.usagePage {
        lines.append("usage_page = \(String(format: "0x%04x", up))")
    }
    if let u = model.device.usage {
        lines.append("usage = \(String(format: "0x%04x", u))")
    }
    if !model.device.protocolName.isEmpty && model.device.protocolName != "vendor" {
        lines.append("protocol = \(escapeString(model.device.protocolName))")
    }
    lines.append("")

    // [layout]
    lines.append("[layout]")
    lines.append("rows = \(model.layout.rows)")
    lines.append("cols = \(model.layout.cols)")
    lines.append("knobs = \(model.layout.knobs)")
    lines.append("")

    // [app]
    lines.append("[app]")
    lines.append("statusbar = \(model.app.statusbar ? "true" : "false")")
    lines.append("log_level = \(escapeString(model.app.logLevel))")
    if let icon = model.app.icon {
        lines.append("icon = \(escapeString(icon))")
    }
    lines.append("launch_at_login = \(model.app.launchAtLogin ? "true" : "false")")
    lines.append("")

    // [[key]]
    for k in model.keys {
        if let act = k.action {
            lines.append("[[key]]")
            lines.append("row = \(k.row)")
            lines.append("col = \(k.col)")
            lines.append("action = \(actionToInlineTable(act))")
            lines.append("")
        }
    }

    // [[knob]]
    for kn in model.knobs {
        if kn.onCW != nil || kn.onCCW != nil || kn.onPress != nil {
            lines.append("[[knob]]")
            lines.append("index = \(kn.index)")
            if let cw = kn.onCW {
                lines.append("on_cw = \(actionToInlineTable(cw))")
            }
            if let ccw = kn.onCCW {
                lines.append("on_ccw = \(actionToInlineTable(ccw))")
            }
            if let press = kn.onPress {
                lines.append("on_press = \(actionToInlineTable(press))")
            }
            lines.append("")
        }
    }

    return lines.joined(separator: "\n")
}
