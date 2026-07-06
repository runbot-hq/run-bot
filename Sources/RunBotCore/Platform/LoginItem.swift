// LoginItem.swift
// RunBotCore
import ServiceManagement

/// Manages the app's launch-at-login registration via `SMAppService`.
///
/// Moved from `RunBot` to `RunBotCore` in #1623.
public enum LoginItem {
    /// `true` when the app is registered to launch at login.
    /// Checks the live `SMAppService` status — reflects changes made
    /// outside the app (e.g. via System Settings > General > Login Items).
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters launch-at-login based on `enabled`.
    /// Called from the login-item toggle in `SettingsView` via the two-argument
    /// `onChange(of:)` form, which supplies the new toggle value directly.
    /// Errors are logged to stderr but otherwise swallowed — failure is non-fatal
    /// since the toggle will reflect the unchanged state via `LoginItem.isEnabled`.
    public static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("[RunBot] LoginItem.setEnabled(\(enabled)) failed: \(error)", category: .services)
        }
    }
}
