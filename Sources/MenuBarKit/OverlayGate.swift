// OverlayGate.swift
// MenuBarKit

import Foundation
import Observation

@Observable
@MainActor
public final class MBKOverlayGate {
    /// True whenever ANY overlay (sheet, alert, file picker) is active.
    /// Blocks outside-click popover dismiss and workspace-switch dismiss.
    ///
    /// WHY public var AND NOT public internal(set) var:
    ///   @Observable synthesizes its own storage and observation hooks via the
    ///   macro. internal(set) conflicts with the macro's generated accessors in
    ///   Swift 5.9/5.10 and causes compiler errors. Write access is therefore
    ///   guarded by convention rather than by the type system.
    ///
    /// ⚠️ MBK manages this flag internally. Host apps should not write this
    /// directly — doing so can break dismiss-gate invariants mid-session.
    public var hasActiveOverlay: Bool = false {
        didSet {
            mbkLog("OverlayGate", "hasActiveOverlay: \(oldValue) → \(self.hasActiveOverlay)")
        }
    }

    /// True specifically when a file picker panel is open.
    /// Used by PopoverController's event monitor to distinguish an outside
    /// click aimed at the picker from a genuine dismiss gesture, even when
    /// a sheet child window is simultaneously present.
    ///
    /// WHY public var AND NOT public internal(set) var:
    ///   Same reason as hasActiveOverlay above — @Observable macro incompatibility.
    ///
    /// ⚠️ MBK manages this flag internally. Host apps should not write this
    /// directly — doing so can break dismiss-gate invariants mid-session.
    public var hasFilePickerOverlay: Bool = false {
        didSet {
            mbkLog("OverlayGate", "hasFilePickerOverlay: \(oldValue) → \(self.hasFilePickerOverlay)")
        }
    }

    public init() {
        mbkLog("OverlayGate", "init")
    }
}
