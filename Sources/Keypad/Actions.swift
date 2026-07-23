/**
 Action execution engine for macro keypad triggers on macOS.
 */

import AppKit
import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: "Keypad", category: "Actions")

// MARK: - Constants & Key Maps

public let keyCodes: [String: CGKeyCode] = [
    "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
    "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
    "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
    "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
    "y": 0x10, "z": 0x06,
    "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17,
    "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
    "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
    "backspace": 0x33, "delete": 0x33, "escape": 0x35, "esc": 0x35,
    "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    "[": 0x21, "]": 0x1E, ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F,
    "/": 0x2C, "\\": 0x2A, "`": 0x32, "-": 0x1B, "=": 0x18
]

public let modifierMasks: [String: CGEventFlags] = [
    "cmd": .maskCommand,
    "command": .maskCommand,
    "shift": .maskShift,
    "alt": .maskAlternate,
    "option": .maskAlternate,
    "opt": .maskAlternate,
    "ctrl": .maskControl,
    "control": .maskControl
]

public let mediaKeyMap: [String: Int] = [
    "volume_up": 0,
    "volume_down": 1,
    "brightness_up": 2,
    "brightness_down": 3,
    "mute": 7,
    "play_pause": 16,
    "next": 17,
    "previous": 18
]

// MARK: - Chord Parsing

public func parseChord(_ chord: String) -> (flags: CGEventFlags, keyCode: CGKeyCode)? {
    let trimmed = chord.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        logger.error("Invalid key chord: must be a non-empty string")
        return nil
    }

    let parts = trimmed.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var flags = CGEventFlags()
    var mainKeyCode: CGKeyCode? = nil

    for part in parts {
        if let mask = modifierMasks[part] {
            flags.insert(mask)
        } else if let code = keyCodes[part] {
            if mainKeyCode != nil {
                logger.error("Chord has multiple main non-modifier keys: \(chord)")
                return nil
            }
            mainKeyCode = code
        } else {
            logger.error("Unknown key or modifier in chord: '\(part)' in '\(chord)'")
            return nil
        }
    }

    guard let finalCode = mainKeyCode else {
        logger.error("No valid main key found in chord: \(chord)")
        return nil
    }

    return (flags, finalCode)
}

// MARK: - Process Execution Helper

@discardableResult
public func runProcess(_ argv: [String]) -> Bool {
    guard let executable = argv.first, !executable.isEmpty else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(argv.dropFirst())

    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            logger.error("Process '\(argv.joined(separator: " "))' exited with status \(process.terminationStatus)")
            return false
        }
        return true
    } catch {
        logger.error("Failed to run process '\(argv.joined(separator: " "))': \(error.localizedDescription)")
        return false
    }
}

// MARK: - Launchd Oneshot Helper

// pmset fails with error 1006 as a daemon child; launchd context works
private func launchdOneshot(label: String, argv: [String]) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let agentsDir = home.appendingPathComponent("Library/LaunchAgents")
    let plistURL = agentsDir.appendingPathComponent("\(label).plist")

    if !FileManager.default.fileExists(atPath: plistURL.path) {
        do {
            try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            let programXML = argv.map { "\t\t<string>\($0)</string>\n" }.joined()
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>Label</key>
            \t<string>\(label)</string>
            \t<key>ProgramArguments</key>
            \t<array>
            \(programXML)\t</array>
            \t<key>RunAtLoad</key>
            \t<false/>
            </dict>
            </plist>
            """
            try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write launchd plist for \(label): \(error.localizedDescription)")
            return
        }
    }

    let uid = getuid()
    let domain = "gui/\(uid)"
    runProcess(["/bin/launchctl", "bootstrap", domain, plistURL.path])
    runProcess(["/bin/launchctl", "kickstart", "\(domain)/\(label)"])
}

private func applescriptQuote(_ s: String) -> String {
    let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

// MARK: - Action Executor

public enum ActionExecutor {
    public static func execute(_ action: KeypadAction) {
        do {
            switch action.type {
            case "macro":
                executeMacro(action)
            case "media":
                executeMedia(action)
            case "app":
                executeApp(action)
            case "script":
                executeScript(action)
            case "shell":
                executeShell(action)
            case "aerospace":
                executeAerospace(action)
            case "url":
                executeUrl(action)
            case "text":
                executeText(action)
            case "applescript":
                executeApplescript(action)
            case "shortcut":
                executeShortcut(action)
            case "system":
                executeSystem(action)
            case "volume":
                executeVolume(action)
            case "notification":
                executeNotification(action)
            case "sequence":
                executeSequence(action)
            default:
                logger.error("Unknown action type: \(action.type)")
            }
        }
    }

    private static func executeMacro(_ action: KeypadAction) {
        guard let chords = action.keys, !chords.isEmpty else {
            logger.error("Macro action missing keys")
            return
        }

        for chord in chords {
            guard let (flags, keyCode) = parseChord(chord) else { continue }

            if let eventDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
                eventDown.flags = flags
                eventDown.post(tap: .cghidEventTap)
            }
            if let eventUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                eventUp.flags = flags
                eventUp.post(tap: .cghidEventTap)
            }
        }
    }

    private static func executeMedia(_ action: KeypadAction) {
        guard let control = action.control, let keyCode = mediaKeyMap[control] else {
            let ctrlStr = action.control ?? "nil"
            logger.error("Unknown or missing media control: \(ctrlStr)")
            return
        }

        func postMediaKey(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = (keyCode << 16) | ((down ? 0x0a : 0x0b) << 8)
            if let nsEv = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ), let cgEv = nsEv.cgEvent {
                cgEv.post(tap: .cghidEventTap)
            }
        }

        postMediaKey(down: true)
        postMediaKey(down: false)
    }

    private static func executeApp(_ action: KeypadAction) {
        if let name = action.name, !name.isEmpty {
            runProcess(["/usr/bin/open", "-a", name])
        } else if let path = action.path, !path.isEmpty {
            runProcess(["/usr/bin/open", path])
        } else {
            logger.error("App action missing both name and path")
        }
    }

    private static func executeScript(_ action: KeypadAction) {
        guard let path = action.path, !path.isEmpty else {
            logger.error("Script action missing path")
            return
        }
        runProcess([path] + action.args)
    }

    private static func executeShell(_ action: KeypadAction) {
        guard let command = action.command, !command.isEmpty else {
            logger.error("Shell action missing command")
            return
        }
        runProcess(["/bin/sh", "-c", command])
    }

    private static func executeAerospace(_ action: KeypadAction) {
        guard let command = action.command, !command.isEmpty else {
            logger.error("Aerospace action missing command")
            return
        }
        let candidates = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
        var binaryPath: String? = nil

        if FileManager.default.fileExists(atPath: "/usr/bin/which") {
            let pipe = Pipe()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            p.arguments = ["aerospace"]
            p.standardOutput = pipe
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0, let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
                binaryPath = out
            }
        }

        if binaryPath == nil {
            for cand in candidates {
                if FileManager.default.fileExists(atPath: cand) {
                    binaryPath = cand
                    break
                }
            }
        }

        guard let executable = binaryPath else {
            logger.error("AeroSpace CLI not found (install AeroSpace or add it to PATH)")
            return
        }

        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        runProcess([executable] + parts)
    }

    private static func executeUrl(_ action: KeypadAction) {
        guard let urlStr = action.url, !urlStr.isEmpty else {
            logger.error("URL action missing url")
            return
        }
        runProcess(["/usr/bin/open", urlStr])
    }

    private static func executeText(_ action: KeypadAction) {
        guard let textStr = action.text, !textStr.isEmpty else {
            logger.error("Text action missing text")
            return
        }
        let chunkSize = 20
        let chars = Array(textStr)

        for i in stride(from: 0, to: chars.count, by: chunkSize) {
            let end = min(i + chunkSize, chars.count)
            let chunk = String(chars[i..<end])
            let utf16 = Array(chunk.utf16)

            if let eventDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                eventDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                eventDown.post(tap: .cghidEventTap)
            }
            if let eventUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                eventUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                eventUp.post(tap: .cghidEventTap)
            }
        }
    }

    private static func executeApplescript(_ action: KeypadAction) {
        guard let source = action.source, !source.isEmpty else {
            logger.error("AppleScript action missing source")
            return
        }
        runProcess(["/usr/bin/osascript", "-e", source])
    }

    private static func executeShortcut(_ action: KeypadAction) {
        guard let name = action.name, !name.isEmpty else {
            logger.error("Shortcut action missing name")
            return
        }
        runProcess(["/usr/bin/shortcuts", "run", name])
    }

    private static func executeSystem(_ action: KeypadAction) {
        guard let command = action.command, !command.isEmpty else {
            logger.error("System action missing command")
            return
        }

        switch command {
        case "lock_screen":
            runProcess(["/System/Library/PrivateFrameworks/login.framework/Versions/Current/Resources/CGSession", "-suspend"])
        case "display_sleep":
            launchdOneshot(label: "com.keypad.displaysleep", argv: ["/usr/bin/pmset", "displaysleepnow"])
        case "system_sleep":
            launchdOneshot(label: "com.keypad.systemsleep", argv: ["/usr/bin/pmset", "sleepnow"])
        case "screensaver":
            runProcess(["/usr/bin/open", "-a", "ScreenSaverEngine"])
        case "mission_control":
            runProcess(["/usr/bin/open", "-a", "Mission Control"])
        case "launchpad":
            runProcess(["/usr/bin/open", "-a", "Launchpad"])
        case "show_desktop":
            runProcess(["/usr/bin/osascript", "-e", "tell application \"System Events\" to key code 103"])
        case "toggle_dark_mode":
            runProcess(["/usr/bin/osascript", "-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"])
        default:
            logger.error("Unknown system command: \(command)")
        }
    }

    private static func executeVolume(_ action: KeypadAction) {
        guard let level = action.level else {
            logger.error("Volume action missing level")
            return
        }
        runProcess(["/usr/bin/osascript", "-e", "set volume output volume \(level)"])
    }

    private static func executeNotification(_ action: KeypadAction) {
        guard let textStr = action.text, !textStr.isEmpty else {
            logger.error("Notification action missing text")
            return
        }
        var script = "display notification \(applescriptQuote(textStr))"
        if let title = action.title, !title.isEmpty {
            script += " with title \(applescriptQuote(title))"
        }
        runProcess(["/usr/bin/osascript", "-e", script])
    }

    private static func executeSequence(_ action: KeypadAction) {
        for (i, step) in action.steps.enumerated() {
            if i > 0 && action.delay > 0 {
                Thread.sleep(forTimeInterval: action.delay)
            }
            execute(step)
        }
    }
}
