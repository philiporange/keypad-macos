/**
 HID input report decoders converting raw bytes into structured key and knob events.
 */

import Foundation

// MARK: - Enums & Protocols

public enum KnobDirection: String, Equatable {
    case cw
    case ccw
    case press
}

public enum KeypadEvent: Equatable {
    case key(row: Int, col: Int, pressed: Bool)
    case knob(index: Int, direction: KnobDirection)
}

public protocol ReportDecoder: AnyObject {
    func decode(_ data: [UInt8]) -> KeypadEvent?
}

// MARK: - Vendor Report Decoder

public final class VendorReportDecoder: ReportDecoder {
    public var rows: Int
    public var cols: Int
    public var knobs: Int

    public init(rows: Int = 0, cols: Int = 0, knobs: Int = 0) {
        self.rows = rows
        self.cols = cols
        self.knobs = knobs
    }

    public func decode(_ data: [UInt8]) -> KeypadEvent? {
        guard data.count >= 3 else { return nil }

        let reportType = data[0]

        if reportType == 1 {
            // Key report: byte 1 = key_index, byte 2 = pressed (0 or 1)
            let keyIndex = Int(data[1])
            let pressedVal = data[2]
            guard pressedVal == 0 || pressedVal == 1 else { return nil }
            guard cols > 0 && rows > 0 else { return nil }

            let row = keyIndex / cols
            let col = keyIndex % cols

            guard keyIndex < rows * cols && row < rows && col < cols else { return nil }

            return .key(row: row, col: col, pressed: pressedVal == 1)
        } else if reportType == 2 {
            // Knob report: byte 1 = knob_index, byte 2 = direction (1: cw, 2: ccw, 3: press)
            let knobIndex = Int(data[1])
            let dirVal = data[2]

            let dirMap: [UInt8: KnobDirection] = [1: .cw, 2: .ccw, 3: .press]
            guard let dir = dirMap[dirVal] else { return nil }
            guard knobIndex >= 0 && knobIndex < knobs else { return nil }

            return .knob(index: knobIndex, direction: dir)
        }

        return nil
    }
}

// MARK: - Keyboard Report Decoder

public final class KeyboardReportDecoder: ReportDecoder {
    public static let f13Usage: UInt8 = 0x68
    public static let ctrlMask: UInt8 = 0x11
    public static let knobDirections: [KnobDirection] = [.ccw, .press, .cw]

    public var rows: Int
    public var cols: Int
    public var knobs: Int

    private var held: Set<HeldItem> = []

    private struct HeldItem: Hashable {
        let isCtrl: Bool
        let usage: UInt8
    }

    public init(rows: Int = 0, cols: Int = 0, knobs: Int = 0) {
        self.rows = rows
        self.cols = cols
        self.knobs = knobs
    }

    public func decode(_ data: [UInt8]) -> KeypadEvent? {
        guard let (modifier, usages) = parseReport(data) else { return nil }

        let isCtrl = (modifier & Self.ctrlMask) != 0
        let current = Set(usages.map { HeldItem(isCtrl: isCtrl, usage: $0) })

        let pressed = current.subtracting(held)
        let released = held.subtracting(current)
        held = current

        for item in pressed {
            if let event = eventFor(isCtrl: item.isCtrl, usage: item.usage, pressed: true) {
                return event
            }
        }
        for item in released {
            if let event = eventFor(isCtrl: item.isCtrl, usage: item.usage, pressed: false) {
                if case .key = event {
                    return event
                }
            }
        }

        return nil
    }

    private func parseReport(_ data: [UInt8]) -> (UInt8, [UInt8])? {
        guard !data.isEmpty else { return nil }
        if data.count >= 9 && (data[0] == 1 || data[0] == 2) {
            let modifier = data[1]
            let usages = Array(data[3..<9]).filter { $0 != 0 }
            return (modifier, usages)
        }
        if data.count == 8 {
            let modifier = data[0]
            let usages = Array(data[2..<8]).filter { $0 != 0 }
            return (modifier, usages)
        }
        return nil
    }

    private func eventFor(isCtrl: Bool, usage: UInt8, pressed: Bool) -> KeypadEvent? {
        guard usage >= Self.f13Usage else { return nil }
        let index = Int(usage - Self.f13Usage)
        if isCtrl {
            let knobIndex = index / Self.knobDirections.count
            let dirIndex = index % Self.knobDirections.count
            guard knobIndex < knobs else { return nil }
            guard pressed else { return nil }
            return .knob(index: knobIndex, direction: Self.knobDirections[dirIndex])
        } else {
            guard cols > 0 && index < rows * cols else { return nil }
            return .key(row: index / cols, col: index % cols, pressed: pressed)
        }
    }
}

// MARK: - Factory Function

public func makeDecoder(for config: Config) -> ReportDecoder {
    if config.device.protocolName == "keyboard" {
        return KeyboardReportDecoder(rows: config.layout.rows, cols: config.layout.cols, knobs: config.layout.knobs)
    } else {
        return VendorReportDecoder(rows: config.layout.rows, cols: config.layout.cols, knobs: config.layout.knobs)
    }
}
