// MigrationSettingsDetailView.swift
// RunBot

import AppUpdater
import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - MigrationSettingsDetailView

/// Right-hand detail pane for the two-pane settings layout.
///
/// Routes the selected `MigrationSettingsSection` to the appropriate
/// existing settings section view. All section views are reused unchanged;
/// this view is purely a router.
///
/// ## Dependency rules
/// - `GitHubAuthentication` is read from the environment (same instance as
///   `MigrationSettingsView` used to own).
/// - `onToggleEnvironment` calls `authentication.setSelectedSource` directly
///   on that environment object, preserving the existing behaviour.
/// - No new plumbing through `AppShellView` or `AppDetailView` is required.
@MainActor
struct MigrationSettingsDetailView: View {

    // MARK: - Environment

    /// The active GitHub authentication state, injected from the environment.
    @Environment(GitHubAuthentication.self)
    private var authentication

    // MARK: - Inputs

    /// The section currently selected in the list pane.
    let selection: MigrationSettingsSection?

    /// Services required by the settings sections.
    let dependencies: MigrationSettingsDependencies

    // MARK: - Body

    var body: some View {
        switch selection ?? .authentication {
        case .authentication:
            AuthenticationSection(
                authentication: authentication,
                onSignIn: dependencies.onSignIn,
                onSignOut: { Task { await dependencies.onSignOut() } },
                onToggleEnvironment: { enabled in
                    if enabled {
                        authentication.setSelectedSource(.environment)
                    } else {
                        authentication.setSelectedSource(.unauthenticated)
                    }
                }
            )
        case .general:
            GeneralSettingsSection()
        case .updates:
            UpdateSettingsSection(
                settings: dependencies.settings,
                runnerState: dependencies.runnerState,
                autoUpdater: dependencies.autoUpdater
            )
        case .about:
            AboutSettingsSection()
        }
    }
}
