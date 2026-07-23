/**
 Unit tests for Keypad event decoding.
 */

import XCTest
@testable import Keypad

final class EventsTests: XCTestCase {
    // MARK: - Helpers

    private func kbReport(_ mod: UInt8, _ usages: UInt8...) -> [UInt8] {
        let keys = usages + Array(repeating: 0, count: max(0, 6 - usages.count))
        return [2, mod, 0] + Array(keys.prefix(6))
    }

    // MARK: - Vendor Decoder Tests

    func testVendorDecoderGridCorners() {
        let decoder = VendorReportDecoder(rows: 3, cols: 4, knobs: 2)

        // Top-left corner: key 0 pressed -> (0, 0, true)
        XCTAssertEqual(decoder.decode([1, 0, 1]), .key(row: 0, col: 0, pressed: true))

        // Top-left corner: key 0 released -> (0, 0, false)
        XCTAssertEqual(decoder.decode([1, 0, 0]), .key(row: 0, col: 0, pressed: false))

        // Bottom-right corner: key 11 -> (2, 3, true)
        XCTAssertEqual(decoder.decode([1, 11, 1]), .key(row: 2, col: 3, pressed: true))
    }

    func testVendorDecoderKnobs() {
        let decoder = VendorReportDecoder(rows: 3, cols: 4, knobs: 2)

        // Knob 0 CW
        XCTAssertEqual(decoder.decode([2, 0, 1]), .knob(index: 0, direction: .cw))
        // Knob 0 CCW
        XCTAssertEqual(decoder.decode([2, 0, 2]), .knob(index: 0, direction: .ccw))
        // Knob 0 Press
        XCTAssertEqual(decoder.decode([2, 0, 3]), .knob(index: 0, direction: .press))
        // Knob 1 CW
        XCTAssertEqual(decoder.decode([2, 1, 1]), .knob(index: 1, direction: .cw))
    }

    func testVendorDecoderUnknownAndShortReports() {
        let decoder = VendorReportDecoder(rows: 3, cols: 4, knobs: 2)

        // Short report (< 3 bytes)
        XCTAssertNil(decoder.decode([1, 0]))
        XCTAssertNil(decoder.decode([]))

        // Unknown report type (byte 0 not 1 or 2)
        XCTAssertNil(decoder.decode([3, 0, 1]))

        // Out of bounds key index
        XCTAssertNil(decoder.decode([1, 20, 1]))

        // Out of bounds knob index
        XCTAssertNil(decoder.decode([2, 5, 1]))

        // Invalid press value / knob direction byte
        XCTAssertNil(decoder.decode([1, 0, 5]))
        XCTAssertNil(decoder.decode([2, 0, 5]))
    }

    // MARK: - Keyboard Decoder Tests

    func testKeyboardDecoderGridCorners() {
        let decoder = KeyboardReportDecoder(rows: 3, cols: 4, knobs: 2)

        XCTAssertEqual(decoder.decode(kbReport(0, 0x68)), .key(row: 0, col: 0, pressed: true))
        XCTAssertEqual(decoder.decode(kbReport(0)), .key(row: 0, col: 0, pressed: false))

        XCTAssertEqual(decoder.decode(kbReport(0, 0x6B)), .key(row: 0, col: 3, pressed: true))
        XCTAssertEqual(decoder.decode(kbReport(0)), .key(row: 0, col: 3, pressed: false))

        XCTAssertEqual(decoder.decode(kbReport(0, 0x70)), .key(row: 2, col: 0, pressed: true))
        XCTAssertEqual(decoder.decode(kbReport(0)), .key(row: 2, col: 0, pressed: false))

        XCTAssertEqual(decoder.decode(kbReport(0, 0x73)), .key(row: 2, col: 3, pressed: true))
        XCTAssertEqual(decoder.decode(kbReport(0)), .key(row: 2, col: 3, pressed: false))
    }

    func testKeyboardDecoderKnobs() {
        let decoder = KeyboardReportDecoder(rows: 3, cols: 4, knobs: 2)

        XCTAssertEqual(decoder.decode(kbReport(0x01, 0x68)), .knob(index: 0, direction: .ccw))
        XCTAssertNil(decoder.decode(kbReport(0x01))) // knob release: no event

        XCTAssertEqual(decoder.decode(kbReport(0x01, 0x69)), .knob(index: 0, direction: .press))
        XCTAssertNil(decoder.decode(kbReport(0x01)))

        XCTAssertEqual(decoder.decode(kbReport(0x01, 0x6A)), .knob(index: 0, direction: .cw))
        XCTAssertNil(decoder.decode(kbReport(0x01)))

        XCTAssertEqual(decoder.decode(kbReport(0x01, 0x6B)), .knob(index: 1, direction: .ccw))
        XCTAssertNil(decoder.decode(kbReport(0x01)))

        XCTAssertEqual(decoder.decode(kbReport(0x01, 0x6D)), .knob(index: 1, direction: .cw))
    }

    func testKeyboardDecoderHeldKeyNoRepeat() {
        let decoder = KeyboardReportDecoder(rows: 3, cols: 4, knobs: 2)

        XCTAssertEqual(decoder.decode(kbReport(0, 0x68)), .key(row: 0, col: 0, pressed: true))
        XCTAssertNil(decoder.decode(kbReport(0, 0x68)))
        XCTAssertNil(decoder.decode(kbReport(0, 0x68)))
        XCTAssertEqual(decoder.decode(kbReport(0)), .key(row: 0, col: 0, pressed: false))
    }

    func testKeyboardDecoderIgnoresForeignReports() {
        let decoder = KeyboardReportDecoder(rows: 3, cols: 4, knobs: 2)

        XCTAssertNil(decoder.decode([]))
        XCTAssertNil(decoder.decode([9, 1, 2]))
        XCTAssertNil(decoder.decode(kbReport(0, 0x04))) // usage below F13

        let decoder2 = KeyboardReportDecoder(rows: 1, cols: 2, knobs: 1)
        XCTAssertNil(decoder2.decode(kbReport(0, 0x6C))) // F17 > 1x2 grid
        XCTAssertNil(decoder2.decode(kbReport(0x01, 0x6B))) // knob 1 > 1 knob
    }
}
