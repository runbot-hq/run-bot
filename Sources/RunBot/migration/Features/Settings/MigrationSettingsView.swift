// MigrationSettingsView.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - MigrationSettingsView

/// Thin bridge retained for any call-sites that still reference
/// `MigrationSettingsView`. The three-column shell now routes Settings
/// directly through `AppContentView` (list) and `AppDetailView` (detail)
/// so this wrapper is no longer the settings root.
///
/// If no remaining call-sites reference this view it can be deleted once
/// all feature branches have landed.
@MainActor
struct MigrationSettingsView: View {

    // MARK: - Inputs

    /// Services required by the settings sections (forwarded for compatibility).
    let dependencies: MigrationSettingsDependencies

    // MARK: - Body

    /// Empty placeholder — layout is now owned by the app shell columns.
    var body: some View {
        EmptyView()
    }
}
