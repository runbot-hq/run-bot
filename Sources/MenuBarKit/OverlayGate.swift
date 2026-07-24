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
    /// WHY public internal(set) var:
    ///   @Observable synthesizes its own storage and observation hooks via the
    ///   macro. This was previously dropped because internal(set) conflicted
    ///   with the macro's generated accessors in Swift 5.9/5.10. Re-enabled
    ///   to verify whether current toolchain accepts the pattern. If the build
    ///   fails, revert and reinstate the public var + convention-guarded comment.
    ///
    /// ⚠️ MBK manages this flag internally. Host apps should not write this
    /// directly — doing so can break dismiss-gate invariants mid-session.
    public internal(set) var hasActiveOverlay: Bool = false {
        didSet {
            mbkLog("OverlayGate", "hasActiveOverlay: \(oldValue) → \(self.hasActiveOverlay)")
        }
    }

    /// True specifically when a file picker panel is open.
    /// Used by PopoverController's event monitor to distinguish an outside
    /// click aimed at the picker from a genuine dismiss gesture, even when
    /// a sheet child window is simultaneously present.
    ///
    /// ⚠️ MBK manages this flag internally. Host apps should not write this
    /// directly — doing so can break dismiss-gate invariants mid-session.
    public internal(set) var hasFilePickerOverlay: Bool = false {
        didSet {
            mbkLog("OverlayGate", "hasFilePickerOverlay: \(oldValue) → \(self.hasFilePickerOverlay)")
        }
    }

    public init() {
        mbkLog("OverlayGate", "init")
    }
}
