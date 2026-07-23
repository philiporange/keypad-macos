/**
 Launch-at-login management via macOS ServiceManagement.SMAppService.
 */

import Foundation
import os
import ServiceManagement

private let logger = Logger(subsystem: "Keypad", category: "LoginItem")

// MARK: - LoginItem Enum

public enum LoginItem {
    public static var isAvailable: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            return false
        }
        return Bundle.main.bundlePath.hasSuffix(".app")
    }

    public static func isEnabled() -> Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) {
        guard isAvailable else {
            logger.info("LoginItem setEnabled skipped: not running from app bundle")
            return
        }
        guard enabled != isEnabled() else { return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.info("Successfully registered login item")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Successfully unregistered login item")
            }
        } catch {
            logger.error("Failed to \(enabled ? "register" : "unregister") login item: \(error.localizedDescription)")
        }
    }
}
