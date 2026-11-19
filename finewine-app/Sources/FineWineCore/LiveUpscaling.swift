import Foundation
import notify

/// The switch for MetalFX upscaling in a running program.
///
/// DXMT and MoltenVK look, a few times a second, at the state of the Darwin notification
/// "finewine.metalfx.<process id>": 1 is on, 2 is off, 0 means nothing was said and the
/// program goes by how it was started. The program's own View menu sets the same state.
/// The system keeps the state only while something is registered for the name, which a
/// program is once it has drawn; one that has not yet is told again by the caller later.
public enum LiveUpscaling {
    public static func notificationName(processID: Int32) -> String { "finewine.metalfx.\(processID)" }

    /// What a state value means; nil for "not said".
    public static func meaning(ofState state: UInt64) -> Bool? {
        switch state { case 1: return true; case 2: return false; default: return nil }
    }

    public static func state(for on: Bool) -> UInt64 { on ? 1 : 2 }

    /// Switches upscaling in the given processes. Returns how many were told.
    @discardableResult
    public static func set(_ on: Bool, processIDs: [Int32]) -> Int {
        var told = 0
        for pid in processIDs {
            var token: Int32 = 0
            guard notify_register_check(notificationName(processID: pid), &token) == NOTIFY_STATUS_OK else { continue }
            if notify_set_state(token, state(for: on)) == NOTIFY_STATUS_OK { told += 1 }
            notify_cancel(token)
        }
        return told
    }

    /// What a process was last told, nil when nothing.
    public static func current(processID: Int32) -> Bool? {
        var token: Int32 = 0
        guard notify_register_check(notificationName(processID: processID), &token) == NOTIFY_STATUS_OK else { return nil }
        defer { notify_cancel(token) }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == NOTIFY_STATUS_OK else { return nil }
        return meaning(ofState: state)
    }
}
