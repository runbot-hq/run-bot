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
    /// Read-only outside the MenuBarKit module. MBK sets this flag internally
    /// via `mbkSheet`, `mbkAlert`, and `mbkOpenFilePicker`.
    /// Host apps should not write this directly — doing so can break
    /// dismiss-gate invariants mid-session.
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
    /// Read-only outside the MenuBarKit module. MBK sets this flag internally
    /// via `mbkOpenFilePicker`.
    /// Host apps should not write this directly — doing so can break
    /// dismiss-gate invariants mid-session.
    public internal(set) var hasFilePickerOverlay: Bool = false {
        didSet {
            mbkLog("OverlayGate", "hasFilePickerOverlay: \(oldValue) → \(self.hasFilePickerOverlay)")
        }
    }

    public init() {
        mbkLog("OverlayGate", "init")
    }
}
