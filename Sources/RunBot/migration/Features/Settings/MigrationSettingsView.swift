// MigrationSettingsView.swift
// RunBot

import AppUpdater
import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - MigrationSettingsView

/// Two-pane settings destination for the windowed app shell.
///
/// Hosts a horizontal split view with `MigrationSettingsListView` on the left
/// and `MigrationSettingsDetailView` on the right. Selection is owned here so
/// both panes share a single source of truth without extra plumbing.
///
/// ## Layout
/// `HSplitView` is used to match the pattern of the other migration
/// destinations (`MigrationScopeView`, `MigrationWorkflowView`).
///
/// ## Dependency rules
/// - `GitHubAuthentication` is read from the SwiftUI environment (owned by
///   `RunBotDesktopApp`). Do not create a second instance here.
/// - OAuth sign-in / sign-out closures and other services are forwarded to the
///   detail view via `MigrationSettingsDependencies`, unchanged from before.
@MainActor
struct MigrationSettingsView: View {

    // MARK: - Environment

    /// The active GitHub authentication state, injected from the environment.
    @Environment(GitHubAuthentication.self)
    private var authentication

    // MARK: - Inputs

    /// Services required by the settings sections.
    let dependencies: MigrationSettingsDependencies

    // MARK: - State

    /// The currently selected settings section.
    @State private var selectedSection: MigrationSettingsSection? = .authentication

    // MARK: - Body

    /// The two-pane settings layout.
    var body: some View {
        HSplitView {
            MigrationSettingsListView(selection: $selectedSection)
            MigrationSettingsDetailView(
                selection: selectedSection,
                dependencies: dependencies
            )
        }
        .navigationTitle("Settings")
    }
}
