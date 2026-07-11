// FilePickerHelper.swift
// StatusBarFilePickerSpike
//
// Wraps NSOpenPanel with the activation-policy dance required for
// accessory (menubar-only) apps so the panel reliably comes to front.
import AppKit

enum FilePickerHelper {

    /// Presents an NSOpenPanel and returns the selected URL, or nil if cancelled.
    ///
    /// ## Activation dance
    /// Menubar apps run with `.accessory` activation policy, meaning macOS does not
    /// consider them "foreground" apps. Without temporarily switching to `.regular`,
    /// the open panel often appears behind other windows.
    ///
    /// - Returns: The selected `URL`, or `nil` if the user cancelled.
    static func pickFile(
        allowedTypes: [String] = [],   // empty = all file types
        canChooseDirectories: Bool = false
    ) -> URL? {
        // 1. Bring app to front so the panel is not buried.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Choose a File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if !allowedTypes.isEmpty {
            // UTType is preferred on macOS 11+, but allowedFileTypes works for a spike.
            panel.allowedFileTypes = allowedTypes
        }

        let result = panel.runModal()

        // 2. Restore accessory policy so the Dock icon disappears again.
        NSApp.setActivationPolicy(.accessory)

        return result == .OK ? panel.url : nil
    }
}
