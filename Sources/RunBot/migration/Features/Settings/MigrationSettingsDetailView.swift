// MigrationSettingsDetailView.swift
// RunBot

import AppUpdater
import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - MigrationSettingsDetailView

/// Detail column for the settings destination.
///
/// Wraps the selected section in a `ScrollView` so Authentication,
/// Updates, and future tall sections remain accessible in short windows.
/// Width is capped at 820 points for readability.
///
/// ## Section composition
/// Each section is wrapped in a `MigrationSettingsSectionLayout` (title +
/// spacing) and the shared section views are wrapped with
/// `.migrationSettingsCard()` where appropriate. The shared section files
/// (`AuthenticationSection`, `GeneralSettingsSection`, etc.) are not modified
/// so they remain safe to reuse from the menu-bar interface.
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

    /// Scrollable detail view with breathing-room padding and readable-width cap.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                detailContent
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(
                maxWidth: 820,
                alignment: .topLeading
            )
        }
    }

    // MARK: - Detail content

    /// Routes the selected section to the appropriate wrapped settings view.
    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .authentication {
        case .authentication:
            MigrationSettingsSectionLayout(title: "Authentication") {
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
            }
        case .general:
            MigrationSettingsSectionLayout(title: "General") {
                GeneralSettingsSection()
                    .migrationSettingsCard()
            }
        case .updates:
            MigrationSettingsSectionLayout(title: "Updates") {
                UpdateSettingsSection(
                    settings: dependencies.settings,
                    runnerState: dependencies.runnerState,
                    autoUpdater: dependencies.autoUpdater
                )
                .migrationSettingsCard()
            }
        case .about:
            MigrationSettingsSectionLayout(title: "About") {
                AboutSettingsSection()
                    .migrationSettingsCard()
            }
        }
    }
}
