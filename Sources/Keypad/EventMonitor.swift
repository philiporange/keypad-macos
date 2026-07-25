/**
 Shared monitor broadcasting decoded keypad events to the configuration UI,
 so physical keypresses can be correlated with the signals the daemon
 actually recognizes.
 */

import Foundation
import Observation

// MARK: - Key Cell

/// A key position in the keypad grid.
public struct KeyCell: Hashable {
    public var row: Int
    public var col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
}

// MARK: - Event Monitor

/// Records every decoded `KeypadEvent` and exposes short-lived "lit" state
/// for the config window: a key flashes orange for `flashDuration` after a
/// press, knobs flash on any rotation or press. Fed by the status bar
/// daemon's event handler and by the standalone configure window's
/// listen-only listeners.
@MainActor
@Observable
public final class EventMonitor {
    public static let shared = EventMonitor()

    /// Grid keys currently flashed in the config UI.
    public private(set) var litKeys: Set<KeyCell> = []
    /// Knob indices currently flashed.
    public private(set) var litKnobs: Set<Int> = []
    /// The most recent decoded event and its arrival time.
    public private(set) var lastEvent: KeypadEvent?
    public private(set) var lastEventDate: Date?

    /// Test mode: while true the daemon still decodes and records events
    /// (so the config UI lights up) but does NOT execute their actions —
    /// most actions steal focus from the config window while testing.
    /// Synced across processes so the standalone configure window can
    /// suspend a separately running daemon. Auto-cleared when the config
    /// window closes.
    public var actionsSuspended: Bool = false {
        didSet {
            guard actionsSuspended != oldValue, !applyingRemoteChange else { return }
            DistributedNotificationCenter.default().postNotificationName(
                Self.suspendNotificationName,
                object: nil,
                userInfo: ["suspended": actionsSuspended],
                deliverImmediately: true
            )
        }
    }

    /// How long a key/knob stays lit after an event.
    public var flashDuration: TimeInterval = 0.6

    private static let suspendNotificationName =
        Notification.Name("com.philiporange.keypad.actionsSuspended")

    @ObservationIgnored private var applyingRemoteChange = false
    @ObservationIgnored private var remoteSyncStarted = false

    /// Mirror suspend-state changes from other Keypad processes (daemon vs.
    /// standalone configure window). Call once per process at startup.
    public func startRemoteSync() {
        guard !remoteSyncStarted else { return }
        remoteSyncStarted = true
        DistributedNotificationCenter.default().addObserver(
            forName: Self.suspendNotificationName, object: nil, queue: .main
        ) { note in
            let suspended = (note.userInfo?["suspended"] as? Bool) ?? false
            Task { @MainActor in
                let monitor = EventMonitor.shared
                monitor.applyingRemoteChange = true
                monitor.actionsSuspended = suspended
                monitor.applyingRemoteChange = false
            }
        }
    }

    // Generation counters so a new flash on the same key extends the light
    // instead of being switched off by the previous flash's timer.
    private var keyGenerations: [KeyCell: Int] = [:]
    private var knobGenerations: [Int: Int] = [:]

    public func record(_ event: KeypadEvent) {
        lastEvent = event
        lastEventDate = Date()

        switch event {
        case .key(let row, let col, let pressed):
            guard pressed else { return }
            flashKey(KeyCell(row: row, col: col))
        case .knob(let index, _):
            flashKnob(index)
        }
    }

    private func flashKey(_ cell: KeyCell) {
        let gen = (keyGenerations[cell] ?? 0) + 1
        keyGenerations[cell] = gen
        litKeys.insert(cell)
        Task { [weak self, flashDuration] in
            try? await Task.sleep(nanoseconds: UInt64(flashDuration * 1_000_000_000))
            guard let self, self.keyGenerations[cell] == gen else { return }
            self.litKeys.remove(cell)
        }
    }

    private func flashKnob(_ index: Int) {
        let gen = (knobGenerations[index] ?? 0) + 1
        knobGenerations[index] = gen
        litKnobs.insert(index)
        Task { [weak self, flashDuration] in
            try? await Task.sleep(nanoseconds: UInt64(flashDuration * 1_000_000_000))
            guard let self, self.knobGenerations[index] == gen else { return }
            self.litKnobs.remove(index)
        }
    }
}
