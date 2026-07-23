/**
 SwiftUI configuration window and models for Keypad settings.
 */

import AppKit
import Foundation
import Observation
import SwiftUI
import TOMLKit
import UniformTypeIdentifiers

// MARK: - Action Model Error

public struct ActionModelError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) {
        self.errorDescription = message
    }
}

// MARK: - Action Model

@Observable
public final class ActionModel {
    public var type: String = "(none)"
    public var keys: String = ""
    public var control: String = "play_pause"
    public var name: String = ""
    public var path: String = ""
    public var argsJoined: String = ""
    public var command: String = ""
    public var url: String = ""
    public var text: String = ""
    public var source: String = ""
    public var title: String = ""
    public var level: String = "50"
    public var stepsTOML: String = ""
    public var delay: String = "0.0"

    public init(from action: KeypadAction? = nil) {
        if let a = action {
            self.type = a.type
            if let k = a.keys {
                self.keys = k.joined(separator: ", ")
            }
            if let c = a.control {
                self.control = c
            }
            if let n = a.name {
                self.name = n
            }
            if let p = a.path {
                self.path = p
            }
            if !a.args.isEmpty {
                self.argsJoined = a.args.joined(separator: " ")
            }
            if let cmd = a.command {
                self.command = cmd
            }
            if let u = a.url {
                self.url = u
            }
            if let t = a.text {
                self.text = t
            }
            if let src = a.source {
                self.source = src
            }
            if let t = a.title {
                self.title = t
            }
            if let l = a.level {
                self.level = String(l)
            }
            if !a.steps.isEmpty {
                let items = a.steps.map { actionToInlineTable($0) }
                self.stepsTOML = "[\(items.joined(separator: ", "))]"
            }
            if a.delay > 0 {
                self.delay = String(a.delay)
            }
        } else {
            self.type = "(none)"
        }
    }

    public func toKeypadAction() throws -> KeypadAction? {
        if type == "(none)" {
            return nil
        }

        switch type {
        case "macro":
            let chords = keys.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !chords.isEmpty else {
                throw ActionModelError("Macro action requires at least one chord")
            }
            return KeypadAction(type: "macro", keys: chords)

        case "media":
            guard validMediaControls.contains(control) else {
                throw ActionModelError("Media action requires valid control")
            }
            return KeypadAction(type: "media", control: control)

        case "app":
            let n = name.trimmingCharacters(in: .whitespaces)
            let p = path.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty || !p.isEmpty else {
                throw ActionModelError("App action requires name or path")
            }
            return KeypadAction(type: "app", name: n.isEmpty ? nil : n, path: p.isEmpty ? nil : p)

        case "script":
            let p = path.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else {
                throw ActionModelError("Script action requires path")
            }
            let args = argsJoined.components(separatedBy: .whitespaces).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return KeypadAction(type: "script", path: p, args: args)

        case "shell":
            let cmd = command.trimmingCharacters(in: .whitespaces)
            guard !cmd.isEmpty else {
                throw ActionModelError("Shell action requires command")
            }
            return KeypadAction(type: "shell", command: cmd)

        case "aerospace":
            let cmd = command.trimmingCharacters(in: .whitespaces)
            guard !cmd.isEmpty else {
                throw ActionModelError("Aerospace action requires string 'command' (e.g. 'workspace 3')")
            }
            return KeypadAction(type: "aerospace", command: cmd)

        case "url":
            let u = url.trimmingCharacters(in: .whitespaces)
            guard !u.isEmpty else {
                throw ActionModelError("URL action requires URL")
            }
            return KeypadAction(type: "url", url: u)

        case "text":
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else {
                throw ActionModelError("Text action requires text")
            }
            return KeypadAction(type: "text", text: t)

        case "applescript":
            let src = source.trimmingCharacters(in: .whitespaces)
            guard !src.isEmpty else {
                throw ActionModelError("AppleScript action requires source code")
            }
            return KeypadAction(type: "applescript", source: src)

        case "shortcut":
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else {
                throw ActionModelError("Shortcut action requires name")
            }
            return KeypadAction(type: "shortcut", name: n)

        case "system":
            let cmd = command.trimmingCharacters(in: .whitespaces)
            guard validSystemCommands.contains(cmd) else {
                throw ActionModelError("System action requires valid command")
            }
            return KeypadAction(type: "system", command: cmd)

        case "volume":
            guard let lvl = Int(level.trimmingCharacters(in: .whitespaces)), (0...100).contains(lvl) else {
                throw ActionModelError("Volume action requires integer level between 0 and 100")
            }
            return KeypadAction(type: "volume", level: lvl)

        case "notification":
            let msg = text.trimmingCharacters(in: .whitespaces)
            guard !msg.isEmpty else {
                throw ActionModelError("Notification action requires message text")
            }
            let t = title.trimmingCharacters(in: .whitespaces)
            return KeypadAction(type: "notification", text: msg, title: t.isEmpty ? nil : t)

        case "sequence":
            let stepsRaw = stepsTOML.trimmingCharacters(in: .whitespaces)
            guard !stepsRaw.isEmpty else {
                throw ActionModelError("Sequence action requires steps")
            }
            let stepsTable: TOMLTable
            do {
                stepsTable = try TOMLTable(string: "steps = \(stepsRaw)")
            } catch {
                throw ActionModelError("Invalid TOML steps array in sequence action: \(error.localizedDescription)")
            }
            guard let stepsArray = stepsTable["steps"]?.array, !stepsArray.isEmpty else {
                throw ActionModelError("Sequence action requires non-empty steps list")
            }
            var steps: [KeypadAction] = []
            for stepItem in stepsArray {
                guard let stepTbl = stepItem.table else {
                    throw ActionModelError("Sequence step must be an action table")
                }
                let stepAction = try parseAction(stepTbl)
                if stepAction.type == "sequence" {
                    throw ActionModelError("Sequence actions cannot be nested")
                }
                steps.append(stepAction)
            }
            let delayVal = Double(delay.trimmingCharacters(in: .whitespaces)) ?? 0.0
            guard delayVal >= 0 else {
                throw ActionModelError("Delay must be a non-negative number of seconds")
            }
            return KeypadAction(type: "sequence", steps: steps, delay: delayVal)

        default:
            throw ActionModelError("Unknown action type: \(type)")
        }
    }
}

// MARK: - Knob Model & Config Model

@Observable
public final class KnobModel {
    public var onCW: ActionModel
    public var onCCW: ActionModel
    public var onPress: ActionModel

    public init(onCW: ActionModel? = nil, onCCW: ActionModel? = nil, onPress: ActionModel? = nil) {
        self.onCW = onCW ?? ActionModel()
        self.onCCW = onCCW ?? ActionModel()
        self.onPress = onPress ?? ActionModel()
    }
}

@Observable
public final class ConfigModel {
    public var vendorHex: String = "0x1234"
    public var productHex: String = "0x5678"
    public var usagePageHex: String = ""
    public var usageHex: String = ""
    public var protocolName: String = "vendor"

    public var rows: Int = 3
    public var cols: Int = 3
    public var knobs: Int = 0

    public var statusbar: Bool = true
    public var logLevel: String = "INFO"
    public var launchAtLogin: Bool = false
    public var icon: String = ""

    public var keysGrid: [[ActionModel]] = []
    public var knobsList: [KnobModel] = []

    public let configPath: String

    public init(configPath: String) {
        self.configPath = configPath
        reloadFromDisk()
    }

    public func reloadFromDisk() {
        guard let cfg = try? loadConfig(atPath: configPath) else { return }

        vendorHex = String(format: "0x%04x", cfg.device.vendorID)
        productHex = String(format: "0x%04x", cfg.device.productID)
        usagePageHex = cfg.device.usagePage.map { String(format: "0x%04x", $0) } ?? ""
        usageHex = cfg.device.usage.map { String(format: "0x%04x", $0) } ?? ""
        protocolName = cfg.device.protocolName

        rows = cfg.layout.rows
        cols = cfg.layout.cols
        knobs = cfg.layout.knobs

        statusbar = cfg.statusbar
        logLevel = cfg.logLevel
        icon = cfg.icon ?? ""
        launchAtLogin = cfg.launchAtLogin || LoginItem.isEnabled()

        // Build keys grid
        var grid: [[ActionModel]] = (0..<rows).map { _ in (0..<cols).map { _ in ActionModel() } }
        for kb in cfg.keys where kb.row < rows && kb.col < cols {
            grid[kb.row][kb.col] = ActionModel(from: kb.action)
        }
        self.keysGrid = grid

        // Build knobs list
        var kList: [KnobModel] = []
        let knobMap = Dictionary(uniqueKeysWithValues: cfg.knobs.map { ($0.index, $0) })
        for idx in 0..<knobs {
            let kn = knobMap[idx]
            kList.append(KnobModel(
                onCW: ActionModel(from: kn?.onCW),
                onCCW: ActionModel(from: kn?.onCCW),
                onPress: ActionModel(from: kn?.onPress)
            ))
        }
        self.knobsList = kList
    }
}

// MARK: - Helper Parsing Functions

private func parseHexOrDecimal(_ s: String, name: String) throws -> Int {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
        throw ActionModelError("\(name) is required")
    }
    if trimmed.lowercased().hasPrefix("0x") {
        let hexPart = trimmed.dropFirst(2)
        guard let val = Int(hexPart, radix: 16) else {
            throw ActionModelError("\(name) must be a valid hex or integer value")
        }
        return val
    }
    guard let val = Int(trimmed, radix: 10) else {
        throw ActionModelError("\(name) must be a valid integer value")
    }
    return val
}

private func parseOptionalHexOrDecimal(_ s: String, name: String) throws -> Int? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    return try parseHexOrDecimal(trimmed, name: name)
}

// MARK: - Command Presets

/// Preset command choices offered in the action editor alongside a free-text
/// "Custom…" option. Static lists for chord/aerospace commands; installed
/// apps and Shortcuts are discovered from the system once per app run.
enum Presets {
    static let macroChords = [
        "cmd+c", "cmd+v", "cmd+x", "cmd+z", "cmd+shift+z",
        "cmd+t", "cmd+w", "cmd+n", "cmd+q", "cmd+tab", "cmd+space",
        "cmd+shift+4", "cmd+shift+5",
    ]

    static let aerospaceCommands = [
        "workspace 1", "workspace 2", "workspace 3", "workspace 4", "workspace 5",
        "workspace next --wrap-around", "workspace prev --wrap-around",
        "workspace-back-and-forth",
        "focus left", "focus right", "focus up", "focus down",
        "move left", "move right", "move up", "move down",
        "fullscreen", "balance-sizes",
        "layout tiles horizontal vertical", "layout accordion horizontal vertical",
        "move-workspace-to-monitor --wrap-around next",
    ]

    /// Names of installed applications from the standard locations.
    static let installedApps: [String] = {
        let dirs = ["/Applications", "/System/Applications",
                    NSHomeDirectory() + "/Applications"]
        var names: Set<String> = []
        for dir in dirs {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for entry in entries where entry.hasSuffix(".app") {
                names.insert(String(entry.dropLast(4)))
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    /// Names of the user's Shortcuts, from `shortcuts list`. Empty if the
    /// CLI fails; the editor then falls back to a plain text field.
    static let shortcuts: [String] = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        } catch {
            return []
        }
    }()
}

// MARK: - Preset Text Field

/// A picker over preset values with a trailing "Custom…" choice that reveals
/// a free-text field. With no presets it degrades to a plain text field.
struct PresetTextField: View {
    let label: String
    let presets: [String]
    let prompt: String
    @Binding var value: String

    private static let customTag = "__custom__"
    @State private var choice: String = PresetTextField.customTag
    @State private var initialized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if presets.isEmpty {
                Text("\(label):").font(.caption)
                TextField(prompt, text: $value)
            } else {
                Picker(label, selection: $choice) {
                    ForEach(presets, id: \.self) { p in
                        Text(p).tag(p)
                    }
                    Divider()
                    Text("Custom…").tag(Self.customTag)
                }
                .onAppear {
                    guard !initialized else { return }
                    initialized = true
                    choice = presets.contains(value) ? value : Self.customTag
                }
                .onChange(of: choice) { _, newChoice in
                    if newChoice != Self.customTag {
                        value = newChoice
                    }
                    // Switching to Custom keeps the current value as the
                    // starting point for editing.
                }
                if choice == Self.customTag {
                    TextField(prompt, text: $value)
                }
            }
        }
    }
}

// MARK: - Action Editor View

public struct ActionEditorView: View {
    @Bindable public var actionModel: ActionModel

    public init(actionModel: ActionModel) {
        self.actionModel = actionModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Action", selection: $actionModel.type) {
                Text("(none)").tag("(none)")
                ForEach(validActionTypes.sorted(), id: \.self) { t in
                    Text(t).tag(t)
                }
            }
            .pickerStyle(.menu)

            Divider()

            switch actionModel.type {
            case "macro":
                VStack(alignment: .leading, spacing: 6) {
                    PresetTextField(
                        label: "Chord",
                        presets: Presets.macroChords,
                        prompt: "e.g. cmd+shift+4, cmd+c",
                        value: $actionModel.keys
                    )
                    Text("Custom entries may list several chords, comma-separated.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            case "media":
                Picker("Control", selection: $actionModel.control) {
                    ForEach(validMediaControls.sorted(), id: \.self) { c in
                        Text(c).tag(c)
                    }
                }
            case "app":
                VStack(alignment: .leading, spacing: 6) {
                    PresetTextField(
                        label: "App",
                        presets: Presets.installedApps,
                        prompt: "App name",
                        value: $actionModel.name
                    )
                    TextField("Path (optional, overrides app name)", text: $actionModel.path)
                }
            case "script":
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Script path", text: $actionModel.path)
                    TextField("Arguments", text: $actionModel.argsJoined)
                }
            case "shell":
                VStack(alignment: .leading) {
                    Text("Command:")
                        .font(.caption)
                    TextField("Command", text: $actionModel.command)
                }
            case "aerospace":
                PresetTextField(
                    label: "Command",
                    presets: Presets.aerospaceCommands,
                    prompt: "e.g. workspace 3",
                    value: $actionModel.command
                )
            case "url":
                VStack(alignment: .leading) {
                    Text("URL:")
                        .font(.caption)
                    TextField("https://...", text: $actionModel.url)
                }
            case "text":
                VStack(alignment: .leading) {
                    Text("Text to type:")
                        .font(.caption)
                    TextField("Text", text: $actionModel.text)
                }
            case "applescript":
                VStack(alignment: .leading) {
                    Text("Source:")
                        .font(.caption)
                    TextEditor(text: $actionModel.source)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 100)
                        .border(Color.secondary.opacity(0.3))
                }
            case "shortcut":
                PresetTextField(
                    label: "Shortcut",
                    presets: Presets.shortcuts,
                    prompt: "Shortcut name",
                    value: $actionModel.name
                )
            case "system":
                Picker("Command", selection: $actionModel.command) {
                    ForEach(validSystemCommands.sorted(), id: \.self) { sysCmd in
                        Text(sysCmd).tag(sysCmd)
                    }
                }
            case "volume":
                VStack(alignment: .leading) {
                    Text("Level (0-100):")
                        .font(.caption)
                    TextField("50", text: $actionModel.level)
                }
            case "notification":
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Title (optional)", text: $actionModel.title)
                    TextField("Message", text: $actionModel.text)
                }
            case "sequence":
                VStack(alignment: .leading, spacing: 6) {
                    Text("Steps (TOML array of inline tables):")
                        .font(.caption)
                    TextEditor(text: $actionModel.stepsTOML)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 80)
                        .border(Color.secondary.opacity(0.3))
                    HStack {
                        Text("Delay between steps (s):")
                            .font(.caption)
                        TextField("0.0", text: $actionModel.delay)
                            .frame(width: 80)
                    }
                }
            default:
                EmptyView()
            }
        }
        .padding(8)
    }
}

// MARK: - Tab Views

private struct GeneralView: View {
    @Bindable var model: ConfigModel

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .disabled(!LoginItem.isAvailable)
                if !LoginItem.isAvailable {
                    Text("Launch at login requires running from an application bundle (.app).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Toggle("Show menu bar icon", isOn: $model.statusbar)

            Picker("Log level", selection: $model.logLevel) {
                Text("DEBUG").tag("DEBUG")
                Text("INFO").tag("INFO")
                Text("WARNING").tag("WARNING")
                Text("ERROR").tag("ERROR")
            }

            Section("Device") {
                TextField("Vendor ID (hex/dec)", text: $model.vendorHex)
                TextField("Product ID (hex/dec)", text: $model.productHex)
                TextField("Usage page (optional)", text: $model.usagePageHex)
                TextField("Usage (optional)", text: $model.usageHex)
                Picker("Protocol", selection: $model.protocolName) {
                    Text("vendor").tag("vendor")
                    Text("keyboard").tag("keyboard")
                }
            }

            Section("Layout") {
                Stepper("Rows: \(model.rows)", value: $model.rows, in: 1...16)
                Stepper("Cols: \(model.cols)", value: $model.cols, in: 1...16)
                Stepper("Knobs: \(model.knobs)", value: $model.knobs, in: 0...8)
            }
        }
        .formStyle(.grouped)
    }
}

struct KeySelection: Hashable {
    var row: Int
    var col: Int
}

private struct KeyGridButton: View {
    let number: Int
    let summary: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack {
                Text("Key \(number)")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(summary)
                    .font(.caption2)
                    .foregroundColor(isSelected ? nil : .secondary)
            }
            .frame(height: 44)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct KeysView: View {
    @Bindable var model: ConfigModel
    @Binding var selectedKey: KeySelection?

    var body: some View {
        VStack(spacing: 12) {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: max(1, model.cols))
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(0..<(model.rows * model.cols), id: \.self) { i in
                        let r = i / model.cols
                        let c = i % model.cols
                        let sel = KeySelection(row: r, col: c)
                        let actionModel = (r < model.keysGrid.count && c < model.keysGrid[r].count)
                            ? model.keysGrid[r][c] : ActionModel()
                        let button = KeyGridButton(
                            number: i + 1,
                            summary: actionModel.type == "(none)" ? "—" : actionModel.type,
                            isSelected: selectedKey == sel
                        ) {
                            selectedKey = sel
                        }
                        if selectedKey == sel {
                            button.buttonStyle(.borderedProminent)
                        } else {
                            button.buttonStyle(.bordered)
                        }
                    }
                }
                .padding(4)
            }

            Divider()

            if let sk = selectedKey, sk.row < model.keysGrid.count, sk.col < model.keysGrid[sk.row].count {
                // .id resets the editor's internal state (preset/custom
                // choice) when a different key is selected.
                ActionEditorView(actionModel: model.keysGrid[sk.row][sk.col])
                    .id(ObjectIdentifier(model.keysGrid[sk.row][sk.col]))
            } else {
                Text("Select a key above to edit its binding.")
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct KnobsView: View {
    @Bindable var model: ConfigModel
    @Binding var selectedKnobIndex: Int
    @Binding var selectedKnobEvent: Int

    var body: some View {
        VStack(spacing: 12) {
            if model.knobs > 0 {
                HStack {
                    Picker("Knob", selection: $selectedKnobIndex) {
                        ForEach(0..<model.knobs, id: \.self) { idx in
                            Text("Knob \(idx)").tag(idx)
                        }
                    }
                    Picker("Event", selection: $selectedKnobEvent) {
                        Text("Rotate CW").tag(0)
                        Text("Rotate CCW").tag(1)
                        Text("Press").tag(2)
                    }
                }

                Divider()

                if selectedKnobIndex < model.knobsList.count {
                    let knobModel = model.knobsList[selectedKnobIndex]
                    let targetActionModel: ActionModel = {
                        switch selectedKnobEvent {
                        case 0: return knobModel.onCW
                        case 1: return knobModel.onCCW
                        default: return knobModel.onPress
                        }
                    }()

                    ActionEditorView(actionModel: targetActionModel)
                        .id(ObjectIdentifier(targetActionModel))
                }
            } else {
                Text("No knobs configured in layout.")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Main Config View

public struct ConfigView: View {
    @Bindable public var model: ConfigModel
    public let configPath: String
    public let onSaved: (() -> Void)?

    @State private var selectedTab: Int = 0
    @State private var selectedKey: KeySelection? = KeySelection(row: 0, col: 0)
    @State private var selectedKnobIndex: Int = 0
    @State private var selectedKnobEvent: Int = 0
    @State private var errorMessage: String? = nil
    @State private var showErrorAlert: Bool = false

    public init(model: ConfigModel, configPath: String, onSaved: (() -> Void)? = nil) {
        self.model = model
        self.configPath = configPath
        self.onSaved = onSaved
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                GeneralView(model: model)
                    .tabItem { Text("General") }
                    .tag(0)

                KeysView(model: model, selectedKey: $selectedKey)
                    .tabItem { Text("Keys") }
                    .tag(1)

                KnobsView(model: model, selectedKnobIndex: $selectedKnobIndex, selectedKnobEvent: $selectedKnobEvent)
                    .tabItem { Text("Knobs") }
                    .tag(2)
            }
            .padding()

            Divider()

            HStack {
                Button("Import…") {
                    importConfig()
                }
                Button("Export…") {
                    exportConfig()
                }
                Spacer()
                Button("Revert") {
                    model.reloadFromDisk()
                }
                Button("Save") {
                    saveConfig()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .alert("Configuration Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    /// Collect the editor state into TOML text, validated through the real
    /// config parser. Throws with a user-readable message on any invalid
    /// field. Shared by Save and Export.
    private func buildValidatedTOML() throws -> String {
        let parsedVendorID = try parseHexOrDecimal(model.vendorHex, name: "Vendor ID")
        let parsedProductID = try parseHexOrDecimal(model.productHex, name: "Product ID")
        let parsedUsagePage = try parseOptionalHexOrDecimal(model.usagePageHex, name: "Usage page")
        let parsedUsage = try parseOptionalHexOrDecimal(model.usageHex, name: "Usage")

        guard model.rows > 0 && model.cols > 0 && model.knobs >= 0 else {
            throw ActionModelError("Rows, cols, and knobs dimensions must be valid positive integers")
        }

        // Collect keys
        var keysDump: [(row: Int, col: Int, action: KeypadAction?)] = []
        for r in 0..<min(model.rows, model.keysGrid.count) {
            let rowGrid = model.keysGrid[r]
            for c in 0..<min(model.cols, rowGrid.count) {
                let actionModel = rowGrid[c]
                let action = try actionModel.toKeypadAction()
                if action != nil {
                    keysDump.append((row: r, col: c, action: action))
                }
            }
        }

        // Collect knobs
        var knobsDump: [(index: Int, onCW: KeypadAction?, onCCW: KeypadAction?, onPress: KeypadAction?)] = []
        for idx in 0..<min(model.knobs, model.knobsList.count) {
            let kn = model.knobsList[idx]
            let cw = try kn.onCW.toKeypadAction()
            let ccw = try kn.onCCW.toKeypadAction()
            let pr = try kn.onPress.toKeypadAction()
            if cw != nil || ccw != nil || pr != nil {
                knobsDump.append((index: idx, onCW: cw, onCCW: ccw, onPress: pr))
            }
        }

        let dump = ConfigDump(
            device: DeviceConfig(
                vendorID: parsedVendorID,
                productID: parsedProductID,
                usagePage: parsedUsagePage,
                usage: parsedUsage,
                protocolName: model.protocolName
            ),
            layout: LayoutConfig(rows: model.rows, cols: model.cols, knobs: model.knobs),
            app: AppDump(
                statusbar: model.statusbar,
                logLevel: model.logLevel,
                icon: model.icon.isEmpty ? nil : model.icon,
                launchAtLogin: model.launchAtLogin
            ),
            keys: keysDump,
            knobs: knobsDump
        )

        let tomlText = dumpsTOML(dump)

        // Round-trip through the real parser so Save/Export can never
        // produce a file the daemon would refuse to load.
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        try tomlText.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        _ = try loadConfig(atPath: tempURL.path)

        return tomlText
    }

    /// Atomically replace the active config file with the given TOML text.
    private func writeActiveConfig(_ tomlText: String) throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        try tomlText.write(to: tempURL, atomically: true, encoding: .utf8)
        let destURL = URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: destURL.path) {
            _ = try FileManager.default.replaceItemAt(destURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: destURL)
        }
    }

    private func saveConfig() {
        do {
            let tomlText = try buildValidatedTOML()
            try writeActiveConfig(tomlText)

            if LoginItem.isAvailable {
                LoginItem.setEnabled(model.launchAtLogin)
            }

            onSaved?()
            model.reloadFromDisk()
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }

    // MARK: - Import / Export

    private func exportConfig() {
        let tomlText: String
        do {
            tomlText = try buildValidatedTOML()
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Keypad Configuration"
        panel.nameFieldStringValue = "keypad.toml"
        if let tomlType = UTType(filenameExtension: "toml") {
            panel.allowedContentTypes = [tomlType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try tomlText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            showErrorAlert = true
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.title = "Import Keypad Configuration"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let tomlType = UTType(filenameExtension: "toml") {
            panel.allowedContentTypes = [tomlType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            // Validate before touching the active config; the imported
            // file's own text is preserved verbatim (comments included).
            _ = try loadConfig(atPath: url.path)
            let tomlText = try String(contentsOf: url, encoding: .utf8)
            try writeActiveConfig(tomlText)
            onSaved?()
            model.reloadFromDisk()
        } catch {
            errorMessage = "Import failed: \(error)"
            showErrorAlert = true
        }
    }
}

// MARK: - Window Controller

@MainActor
public final class ConfigWindowController {
    public let configPath: String
    public let onSaved: (() -> Void)?
    private var window: NSWindow?
    private var model: ConfigModel?

    public init(configPath: String, onSaved: (() -> Void)? = nil) {
        self.configPath = configPath
        self.onSaved = onSaved
    }

    public func show() {
        if model == nil {
            model = ConfigModel(configPath: configPath)
        } else {
            model?.reloadFromDisk()
        }

        if window == nil, let model = model {
            let rootView = ConfigView(model: model, configPath: configPath, onSaved: onSaved)
            let hostingController = NSHostingController(rootView: rootView)
            let win = NSWindow(contentViewController: hostingController)
            win.setContentSize(NSSize(width: 760, height: 640))
            win.title = "Keypad Configuration"
            win.isReleasedWhenClosed = false
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            self.window = win
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
