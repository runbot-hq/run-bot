// MigrationSettingsDetailView.swift
// RunBot

import AppUpdater
import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - MigrationSettingsDetailView

/// Detail column for the settings destination.
///
/// Wraps the selected section view in a `ScrollView` so Authentication,
/// Updates, and future tall sections remain accessible in short windows.
/// Width is constrained to stay readable in wide windows.
///
/// ## Dependency rules
/// - `GitHubAuthentication` is read from the environment (owned by
///   `RunBotDesktopApp`). No second instance is created here.
/// - `onToggleEnvironment` calls `authentication.setSelectedSource` directly.
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

    /// Scrollable detail view with readable-width constraint.
    var body: some View {
        ScrollView {
            detailContent
                .padding(24)
                .frame(
                    minWidth: 520,
                    maxWidth: 760,
                    alignment: .topLeading
                )
        }
    }

    // MARK: - Detail content

    /// Routes the selected section to the appropriate settings view.
    @ViewBuilder
    private var detailContent: some View {
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
