// SettingsSection.swift
// RunBot

import Foundation

// MARK: - SettingsSection

/// Identifies each row in the settings list pane.
///
/// Mirrors the shape of `AppDestination`: `String`-backed, `CaseIterable`,
/// `Identifiable` with `id: Self`, so it can drive a `List(selection:)`
/// binding directly.
enum SettingsSection: String, CaseIterable, Identifiable {

    // MARK: - Cases

    /// GitHub authentication configuration.
    case authentication

    /// General application preferences.
    case general

    /// Automatic update preferences.
    case updates

    // MARK: - Identifiable

    /// Stable identifier backed by the raw string value.
    var id: Self { self }

    // MARK: - Display

    /// Human-readable row label.
    var title: String {
        switch self {
        case .authentication: return "Authentication"
        case .general:        return "General"
        case .updates:        return "Updates"
        }
    }

    /// SF Symbol name for the row icon.
    var systemImage: String {
        switch self {
        case .authentication: return "person.crop.circle"
        case .general:        return "gearshape"
        case .updates:        return "arrow.triangle.2.circlepath"
        }
    }
}
