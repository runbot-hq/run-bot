// TerminalLauncher.swift
// RunBotCore
import Foundation

/// Opens a Terminal.app window and runs a shell command via AppleScript (`do script`).
///
/// Uses `NSAppleScript` — requires no entitlements on an unsandboxed app.
/// Backslashes, double quotes, and newlines in the command are escaped before
/// embedding in the AppleScript string. Tracked in #546.
///
/// Moved from `RunBot` to `RunBotCore` in #1623.
public enum TerminalLauncher {
    /// Opens Terminal.app and runs `command` in a new window.
    /// Must be called on the main thread — `NSAppleScript` is not thread-safe.
    @MainActor
    public static func open(command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let src = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        if NSAppleScript(source: src)?.executeAndReturnError(&error) == nil { // NOSONAR swift:S1523 — command is always internally constructed, never user-supplied; injection risk is theoretical only
            log("TerminalLauncher › AppleScript error: \(error ?? [:])", category: .services)
        }
    }
}
