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
    private var listener: HIDListener?
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

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        do {
            let cfg = try loadConfig(atPath: configPath)
            self.config = cfg
            updateStatusItemIcon(cfg: cfg)
            setupMenu()
            setupListener(cfg: cfg)

            if LoginItem.isAvailable {
                LoginItem.setEnabled(cfg.launchAtLogin)
            }
        } catch {
            logger.error("Failed to load configuration at startup: \(error.localizedDescription)")
            statusItem?.button?.title = "Keypad"
            setupErrorMenu()
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
        listener?.stop()
        let decoder = makeDecoder(for: cfg)
        let newListener = HIDListener(device: cfg.device, decoder: decoder) { [weak self] event in
            guard let self = self, let currentConfig = self.config else { return }
            self.handleEvent(event, cfg: currentConfig)
        }
        self.listener = newListener
        newListener.start()
    }

    private func handleEvent(_ event: KeypadEvent, cfg: Config) {
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
            updateStatusItemIcon(cfg: cfg)
            setupMenu()
            setupListener(cfg: cfg)
            logger.info("Configuration loaded/reloaded.")
        } catch {
            logger.error("Failed to reload configuration: \(error.localizedDescription)")
        }
    }

    @objc private func quitApp() {
        listener?.stop()
        NSApp.terminate(nil)
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
        let controller = ConfigWindowController(configPath: configPath)
        controller.show()
        app.run()
    }
}
