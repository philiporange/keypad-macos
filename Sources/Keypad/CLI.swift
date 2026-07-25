/**
 Command Line Interface and entry point for Keypad.
 */

import Foundation

// MARK: - Action Description Helper

public func describeAction(_ action: KeypadAction) -> String {
    switch action.type {
    case "macro":
        let kStr = action.keys != nil ? "\(action.keys!)" : "nil"
        return "macro(\(kStr))"
    case "media":
        return "media(\(action.control ?? "nil"))"
    case "app":
        let nameStr = action.name ?? "nil"
        let pathStr = action.path ?? "nil"
        return "app(name=\(nameStr), path=\(pathStr))"
    case "script":
        let pathStr = action.path ?? "nil"
        return "script(path=\(pathStr), args=\(action.args))"
    case "shell", "aerospace", "system":
        return "\(action.type)(\(action.command ?? "nil"))"
    case "url":
        return "url(\(action.url ?? "nil"))"
    case "text":
        return "text('\(action.text ?? "")')"
    case "applescript":
        let firstLine = action.source?.components(separatedBy: .newlines).first ?? ""
        return "applescript(\(firstLine)...)"
    case "shortcut":
        return "shortcut(\(action.name ?? "nil"))"
    case "volume":
        let levStr = action.level.map { String($0) } ?? "nil"
        return "volume(\(levStr))"
    case "notification":
        let titleStr = action.title ?? ""
        let textStr = action.text ?? ""
        return "notification(\(titleStr): \(textStr))"
    case "sequence":
        return "sequence(\(action.steps.count) steps, delay=\(action.delay))"
    default:
        return "unknown(\(action.type))"
    }
}

// MARK: - CLI Entry Point

@main
public struct KeypadCLI {
    public static func main() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultConfig = home.appendingPathComponent(".config/keypad/keypad.toml").path

        var args = Array(CommandLine.arguments.dropFirst())

        if args.isEmpty || args[0].hasPrefix("-") {
            args.insert("run", at: 0)
        }

        let subcommand = args[0]

        var configPath = defaultConfig
        var noStatusbar = false
        var learnSeconds = 15.0

        var idx = 1
        while idx < args.count {
            let arg = args[idx]
            if arg == "--config", idx + 1 < args.count {
                configPath = args[idx + 1]
                idx += 2
            } else if arg == "--no-statusbar" {
                noStatusbar = true
                idx += 1
            } else if arg == "--seconds", idx + 1 < args.count {
                if let sec = Double(args[idx + 1]) {
                    learnSeconds = sec
                }
                idx += 2
            } else {
                idx += 1
            }
        }

        switch subcommand {
        case "run":
            do {
                let cfg = try loadConfig(atPath: configPath)
                // The AppKit shell runs even with statusbar = false (the
                // delegate just skips the status item) so that reopening
                // the app can summon the config window. --no-statusbar
                // forces a bare headless loop with no UI at all.
                if !noStatusbar {
                    _ = cfg
                    AppMain.runStatusbar(configPath: configPath)
                } else {
                    let listeners = cfg.devices.map { dev in
                        HIDListener(device: dev, decoder: makeDecoder(for: dev, layout: cfg.layout)) { event in
                            handleEvent(event, cfg: cfg)
                        }
                    }
                    listeners.forEach { $0.start() }
                    RunLoop.main.run()
                }
            } catch {
                fputs("Configuration Error: \(error)\n", stderr)
                exit(1)
            }

        case "list-devices":
            cmdListDevices()

        case "learn":
            cmdLearn(configPath: configPath, seconds: learnSeconds)

        case "check-config":
            cmdCheckConfig(configPath: configPath)

        case "configure":
            AppMain.runConfigureWindow(configPath: configPath)

        default:
            fputs("Unknown command: \(subcommand)\n", stderr)
            exit(1)
        }
    }

    private static func handleEvent(_ event: KeypadEvent, cfg: Config) {
        switch event {
        case .key(let row, let col, let pressed):
            guard pressed else { return }
            for kb in cfg.keys {
                if kb.row == row && kb.col == col {
                    ActionExecutor.execute(kb.action)
                    break
                }
            }
        case .knob(let index, let direction):
            for knb in cfg.knobs {
                if knb.index == index {
                    let act: KeypadAction?
                    switch direction {
                    case .cw: act = knb.onCW
                    case .ccw: act = knb.onCCW
                    case .press: act = knb.onPress
                    }
                    if let action = act {
                        ActionExecutor.execute(action)
                    }
                    break
                }
            }
        }
    }

    private static func cmdCheckConfig(configPath: String) {
        do {
            let cfg = try loadConfig(atPath: configPath)
            print("Configuration valid: \(configPath)")
            for (idx, dev) in cfg.devices.enumerated() {
                let vidHex = String(format: "0x%04x", dev.vendorID)
                let pidHex = String(format: "0x%04x", dev.productID)
                let upStr = dev.usagePage.map { String($0) } ?? "nil"
                let uStr = dev.usage.map { String($0) } ?? "nil"
                let label = cfg.devices.count == 1 ? "Device" : "Device \(idx + 1)"
                print("\(label): \(vidHex):\(pidHex) (usage_page=\(upStr), usage=\(uStr), protocol=\(dev.protocolName))")
            }
            print("Layout: \(cfg.layout.rows)x\(cfg.layout.cols) grid, \(cfg.layout.knobs) knobs")
            print("App Settings: statusbar=\(cfg.statusbar), log_level=\(cfg.logLevel)\n")

            print("Key Bindings:")
            if cfg.keys.isEmpty {
                print("  (None)")
            } else {
                for kb in cfg.keys {
                    print("  Row \(kb.row), Col \(kb.col) -> \(describeAction(kb.action))")
                }
            }

            print("\nKnob Bindings:")
            if cfg.knobs.isEmpty {
                print("  (None)")
            } else {
                for knb in cfg.knobs {
                    if let cw = knb.onCW {
                        print("  Knob \(knb.index) [cw] -> \(describeAction(cw))")
                    }
                    if let ccw = knb.onCCW {
                        print("  Knob \(knb.index) [ccw] -> \(describeAction(ccw))")
                    }
                    if let press = knb.onPress {
                        print("  Knob \(knb.index) [press] -> \(describeAction(press))")
                    }
                }
            }
        } catch {
            fputs("Configuration Error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func cmdListDevices() {
        let devs = listAllHIDDevices()
        if devs.isEmpty {
            print("No HID devices found.")
            return
        }
        print("Found \(devs.count) HID devices:")
        for d in devs {
            let vid = d["vendor_id"] as? Int ?? 0
            let pid = d["product_id"] as? Int ?? 0
            let mfg = d["manufacturer_string"] as? String ?? "Unknown"
            let prod = d["product_string"] as? String ?? "Unknown"
            let upStr = (d["usage_page"] as? Int).map { String($0) } ?? "nil"
            let uStr = (d["usage"] as? Int).map { String($0) } ?? "nil"
            let vidHex = String(format: "0x%04x", vid)
            let pidHex = String(format: "0x%04x", pid)
            print("  - \(vidHex):\(pidHex) | \(mfg) - \(prod) (usage_page: \(upStr), usage: \(uStr))")
        }
    }

    private static func cmdLearn(configPath: String, seconds: Double) {
        do {
            let cfg = try loadConfig(atPath: configPath)
            let ids = cfg.devices
                .map { String(format: "0x%04x:0x%04x", $0.vendorID, $0.productID) }
                .joined(separator: ", ")
            print("Listening for raw reports from device(s) \(ids) for \(seconds)s...")
            learnReports(devices: cfg.devices, seconds: seconds) { device, data in
                let devStr = String(format: "0x%04x:0x%04x", device.vendorID, device.productID)
                let hexStr = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                print("[\(devStr)] Report: \(hexStr)")
            }
        } catch {
            fputs("Error in learn mode: \(error)\n", stderr)
            exit(1)
        }
    }
}
