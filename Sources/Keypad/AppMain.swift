/**
 AppKit application shell for Keypad status bar and standalone configuration window modes.
 */

import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "Keypad", category: "AppMain")

// MARK: - Status Bar App Delegate

@MainActor
private final class StatusbarAppDelegate: NSObject, NSApplicationDelegate {
    let configPath: String
    private var config: Config?
    private var statusItem: NSStatusItem?
    private var listeners: [HIDListener] = []
    private var configWindowController: ConfigWindowController?

    init(configPath: String) {
        self.configPath = configPath
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Macro/media/text actions post CGEvents, which needs Accessibility;
        // request it up front so the grant prompt appears on first run.
        if !CGPreflightPostEventAccess() {
            logger.info("Accessibility (post event) not granted; requesting access")
            CGRequestPostEventAccess()
        }

        // Honour suspend-actions toggles from a standalone configure window.
        EventMonitor.shared.startRemoteSync()

        do {
            let cfg = try loadConfig(atPath: configPath)
            self.config = cfg
            updateStatusItem(cfg: cfg)
            setupListener(cfg: cfg)

            if LoginItem.isAvailable {
                LoginItem.setEnabled(cfg.launchAtLogin)
            }
        } catch {
            logger.error("Failed to load configuration at startup: \(error.localizedDescription)")
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.title = "Keypad"
            setupErrorMenu()
        }
    }

    /// Create or remove the status item to match the config's statusbar
    /// setting. With the item hidden the app stays reachable by launching
    /// Keypad again (see applicationShouldHandleReopen).
    private func updateStatusItem(cfg: Config) {
        if cfg.statusbar {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                setupMenu()
            }
            updateStatusItemIcon(cfg: cfg)
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func updateStatusItemIcon(cfg: Config) {
        var iconPath: String? = nil

        if let customIcon = cfg.icon, !customIcon.isEmpty {
            let expanded = (customIcon as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                iconPath = expanded
            }
        }

        if iconPath == nil {
            if let resourcePath = Bundle.main.path(forResource: "statusbar", ofType: "png") {
                iconPath = resourcePath
            }
        }

        if iconPath == nil {
            let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
            let siblingResource = execURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/keypad.png").path
            if FileManager.default.fileExists(atPath: siblingResource) {
                iconPath = siblingResource
            }
        }

        if let validPath = iconPath, let image = NSImage(contentsOfFile: validPath) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            statusItem?.button?.image = image
            statusItem?.button?.title = ""
        } else {
            statusItem?.button?.image = nil
            statusItem?.button?.title = "Keypad"
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        let itemConfig = NSMenuItem(title: "Configure…", action: #selector(showConfigureWindow), keyEquivalent: "")
        itemConfig.target = self
        menu.addItem(itemConfig)

        let itemReload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "")
        itemReload.target = self
        menu.addItem(itemReload)

        menu.addItem(NSMenuItem.separator())

        let itemQuit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        itemQuit.target = self
        menu.addItem(itemQuit)

        statusItem?.menu = menu
    }

    private func setupErrorMenu() {
        let menu = NSMenu()

        let itemErr = NSMenuItem(title: "Configuration error", action: nil, keyEquivalent: "")
        itemErr.isEnabled = false
        menu.addItem(itemErr)

        let itemReload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "")
        itemReload.target = self
        menu.addItem(itemReload)

        menu.addItem(NSMenuItem.separator())

        let itemQuit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        itemQuit.target = self
        menu.addItem(itemQuit)

        statusItem?.menu = menu
    }

    private func setupListener(cfg: Config) {
        listeners.forEach { $0.stop() }
        // One listener per configured identity (e.g. wireless dongle and
        // wired USB), each with its own decoder — decoders hold per-device
        // held-key state and must not be shared.
        listeners = cfg.devices.map { dev in
            let decoder = makeDecoder(for: dev, layout: cfg.layout)
            return HIDListener(device: dev, decoder: decoder) { [weak self] event in
                guard let self = self, let currentConfig = self.config else { return }
                self.handleEvent(event, cfg: currentConfig)
            }
        }
        listeners.forEach { $0.start() }
    }

    private func handleEvent(_ event: KeypadEvent, cfg: Config) {
        // Feed the config window's live highlight regardless of whether the
        // event is bound to an action.
        EventMonitor.shared.record(event)

        // Test mode: the config window can suspend actions so pad input
        // only lights up the UI instead of firing bindings (most of which
        // would defocus the window being tested from).
        guard !EventMonitor.shared.actionsSuspended else { return }

        switch event {
        case .key(let row, let col, let pressed):
            guard pressed else { return }
            for kb in cfg.keys {
                if kb.row == row && kb.col == col {
                    logger.info("Key press (\(row), \(col)) triggering \(kb.action.type)")
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
                        logger.info("Knob \(index) \(direction.rawValue) triggering \(action.type)")
                        ActionExecutor.execute(action)
                    }
                    break
                }
            }
        }
    }

    @objc private func showConfigureWindow() {
        if configWindowController == nil {
            configWindowController = ConfigWindowController(configPath: configPath) { [weak self] in
                self?.reloadConfig()
            }
        }
        configWindowController?.show()
    }

    @objc private func reloadConfig() {
        do {
            let cfg = try loadConfig(atPath: configPath)
            self.config = cfg
            updateStatusItem(cfg: cfg)
            setupListener(cfg: cfg)
            logger.info("Configuration loaded/reloaded.")
        } catch {
            logger.error("Failed to reload configuration: \(error.localizedDescription)")
        }
    }

    @objc private func quitApp() {
        listeners.forEach { $0.stop() }
        NSApp.terminate(nil)
    }

    /// Launching the app again (Spotlight, Finder) while it is running
    /// opens the config window — the only way in when the menu bar icon
    /// is hidden (statusbar = false).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showConfigureWindow()
        return true
    }
}

// MARK: - AppMain Enum

public enum AppMain {
    @MainActor
    public static func runStatusbar(configPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = StatusbarAppDelegate(configPath: configPath)
        app.delegate = delegate
        app.run()
    }

    @MainActor
    public static func runConfigureWindow(configPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        // Keep suspend-actions state in sync with a running daemon.
        EventMonitor.shared.startRemoteSync()

        // Standalone mode has no daemon in-process, so start listen-only
        // listeners to drive the window's live keypress highlight. No
        // actions are executed here — a running daemon does that; HID
        // listening is non-exclusive, so both can observe at once.
        // The holder keeps the listeners alive for the window's lifetime
        // and lets the @Sendable close-notification block reach them.
        final class MonitorHolder: @unchecked Sendable {
            var listeners: [HIDListener] = []
        }
        let holder = MonitorHolder()
        if let cfg = try? loadConfig(atPath: configPath) {
            holder.listeners = cfg.devices.map { dev in
                let decoder = makeDecoder(for: dev, layout: cfg.layout)
                return HIDListener(device: dev, decoder: decoder) { event in
                    EventMonitor.shared.record(event)
                }
            }
            holder.listeners.forEach { $0.start() }
        }

        let controller = ConfigWindowController(configPath: configPath)
        controller.show()
        // Standalone mode has no menu bar item to return to: closing the
        // window (via the close button, Save, or Revert) quits the process.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // Never leave a running daemon with actions suspended after
                // the window that suspended them is gone.
                EventMonitor.shared.actionsSuspended = false
                holder.listeners.forEach { $0.stop() }
                NSApp.terminate(nil)
            }
        }
        app.run()
    }
}
