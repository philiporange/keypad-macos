/**
 HID listener and background monitoring using macOS IOHIDManager.
 */

import Foundation
import IOKit.hid
import os

private let logger = Logger(subsystem: "Keypad", category: "HIDListener")

// MARK: - HID Listener Class

public final class HIDListener {
    /// Owns the raw report buffer registered with IOKit for one device.
    /// The pointer must stay valid for as long as the callback is
    /// registered, so it is heap-allocated and freed only on removal.
    private final class DeviceContext {
        let buffer: UnsafeMutablePointer<UInt8>
        let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            self.buffer = .allocate(capacity: capacity)
        }

        deinit {
            buffer.deallocate()
        }
    }

    private let deviceConfig: DeviceConfig
    private let decoder: ReportDecoder
    private let onEvent: (KeypadEvent) -> Void

    private var manager: IOHIDManager?
    private var isRunning = false
    private var deviceContexts: [IOHIDDevice: DeviceContext] = [:]

    public init(
        device: DeviceConfig,
        decoder: ReportDecoder,
        onEvent: @escaping (KeypadEvent) -> Void
    ) {
        self.deviceConfig = device
        self.decoder = decoder
        self.onEvent = onEvent
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // Reading keyboard-usage HID devices is gated behind the Input
        // Monitoring permission; ask macOS to show the grant prompt on
        // first run instead of failing silently with kIOReturnNotPermitted.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            logger.info("Input Monitoring not granted; requesting access")
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = mgr

        var matching: [String: Any] = [
            kIOHIDVendorIDKey: deviceConfig.vendorID,
            kIOHIDProductIDKey: deviceConfig.productID
        ]
        if let up = deviceConfig.usagePage {
            matching[kIOHIDDeviceUsagePageKey] = up
        }
        if let u = deviceConfig.usage {
            matching[kIOHIDDeviceUsageKey] = u
        }

        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()

        let matchedCallback: IOHIDDeviceCallback = { context, result, sender, device in
            guard let context = context else { return }
            let listener = Unmanaged<HIDListener>.fromOpaque(context).takeUnretainedValue()
            listener.deviceMatched(device)
        }

        let removalCallback: IOHIDDeviceCallback = { context, result, sender, device in
            guard let context = context else { return }
            let listener = Unmanaged<HIDListener>.fromOpaque(context).takeUnretainedValue()
            listener.deviceRemoved(device)
        }

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, matchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, removalCallback, context)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openStatus = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if openStatus != kIOReturnSuccess {
            logger.warning("IOHIDManagerOpen returned status \(openStatus)")
        }
    }

    public func stop() {
        guard isRunning, let mgr = manager else { return }
        isRunning = false
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        self.deviceContexts.removeAll()
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        let vidHex = String(format: "%04x", deviceConfig.vendorID)
        let pidHex = String(format: "%04x", deviceConfig.productID)
        logger.info("Connected to device (0x\(vidHex):0x\(pidHex))")

        let maxReportSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
        let ctx = DeviceContext(capacity: max(maxReportSize, 8))
        deviceContexts[device] = ctx

        let context = Unmanaged.passUnretained(self).toOpaque()

        let reportCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
            guard let context = context else { return }
            let listener = Unmanaged<HIDListener>.fromOpaque(context).takeUnretainedValue()
            let data = Array(UnsafeBufferPointer(start: report, count: reportLength))
            listener.handleReport(data)
        }

        IOHIDDeviceRegisterInputReportCallback(device, ctx.buffer, ctx.capacity, reportCallback, context)
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let vidHex = String(format: "%04x", deviceConfig.vendorID)
        let pidHex = String(format: "%04x", deviceConfig.productID)
        logger.warning("Device disconnected: 0x\(vidHex):0x\(pidHex)")
        deviceContexts.removeValue(forKey: device)
    }

    private func handleReport(_ data: [UInt8]) {
        if let event = decoder.decode(data) {
            DispatchQueue.main.async { [weak self] in
                self?.onEvent(event)
            }
        }
    }
}

// MARK: - Device Utility Functions

public func listAllHIDDevices() -> [[String: Any]] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    IOHIDManagerSetDeviceMatching(manager, nil)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

    guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        return []
    }

    var result: [[String: Any]] = []

    for device in deviceSet {
        var info: [String: Any] = [:]

        if let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int {
            info["vendor_id"] = vendorID
        }
        if let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int {
            info["product_id"] = productID
        }
        if let mfg = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String {
            info["manufacturer_string"] = mfg
        }
        if let prod = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String {
            info["product_string"] = prod
        }
        if let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int {
            info["usage_page"] = usagePage
        }
        if let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int {
            info["usage"] = usage
        }

        result.append(info)
    }

    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    return result
}

/// Retained context for learn mode: holds the report callback and keeps
/// every registered report buffer alive until the learn window ends.
private final class LearnContext {
    let callback: ([UInt8]) -> Void
    var buffers: [UnsafeMutablePointer<UInt8>] = []

    init(callback: @escaping ([UInt8]) -> Void) {
        self.callback = callback
    }

    deinit {
        for buf in buffers {
            buf.deallocate()
        }
    }
}

/// Listen for raw reports from every configured device at once. The report
/// callback receives the DeviceConfig the report arrived from, so wired and
/// wireless identities can be told apart.
public func learnReports(
    devices: [DeviceConfig],
    seconds: Double,
    onReport: @escaping (DeviceConfig, [UInt8]) -> Void
) {
    var managers: [IOHIDManager] = []
    var rawCtxs: [UnsafeMutableRawPointer] = []

    for device in devices {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        var matching: [String: Any] = [
            kIOHIDVendorIDKey: device.vendorID,
            kIOHIDProductIDKey: device.productID
        ]
        if let up = device.usagePage {
            matching[kIOHIDDeviceUsagePageKey] = up
        }
        if let u = device.usage {
            matching[kIOHIDDeviceUsageKey] = u
        }

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let ctx = LearnContext { data in onReport(device, data) }
        let rawCtx = Unmanaged.passRetained(ctx).toOpaque()

        let matchedCallback: IOHIDDeviceCallback = { context, result, sender, device in
            guard let context = context else { return }
            let lCtx = Unmanaged<LearnContext>.fromOpaque(context).takeUnretainedValue()

            let capacity = 64
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            lCtx.buffers.append(buffer)

            let reportCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
                guard let context = context else { return }
                let lCtx = Unmanaged<LearnContext>.fromOpaque(context).takeUnretainedValue()
                let data = Array(UnsafeBufferPointer(start: report, count: reportLength))
                lCtx.callback(data)
            }

            IOHIDDeviceRegisterInputReportCallback(device, buffer, capacity, reportCallback, context)
        }

        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchedCallback, rawCtx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        managers.append(manager)
        rawCtxs.append(rawCtx)
    }

    RunLoop.main.run(until: Date().addingTimeInterval(seconds))

    for manager in managers {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    for rawCtx in rawCtxs {
        Unmanaged<LearnContext>.fromOpaque(rawCtx).release()
    }
}
