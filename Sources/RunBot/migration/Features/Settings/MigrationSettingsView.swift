// MigrationSettingsView.swift
// RunBot

import AppUpdater
import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - MigrationSettingsView

/// Single-column scrollable settings destination for the windowed app shell.
///
/// Replaces the Step-7 placeholder with a finite-width scroll view that
/// reuses existing authentication, general, update, and about sections.
///
/// ## Layout
/// Content is constrained to 520–760 pt so settings remain readable
/// in a wide application window without stretching labels and controls.
///
/// ## Dependency rules
/// - `GitHubAuthentication` is read from the SwiftUI environment (owned by
///   `RunBotDesktopApp`). Do not create a second instance here.
/// - OAuth sign-in / sign-out are closures on `MigrationSettingsDependencies`
///   built at the app root, so this view never touches `OAuthCredentialController`
///   or `GitHubClient` directly.
/// - `setSelectedSource` is called directly on the environment `authentication`
///   object — the same instance observed by `MigrationScopeView`.
@MainActor
struct MigrationSettingsView: View {

    // MARK: - Environment

    @Environment(GitHubAuthentication.self)
    private var authentication

    // MARK: - Inputs

    let dependencies: MigrationSettingsDependencies

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.largeTitle.weight(.semibold))

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

                GeneralSettingsSection()

                UpdateSettingsSection(
                    settings: dependencies.settings,
                    runnerState: dependencies.runnerState,
                    autoUpdater: dependencies.autoUpdater
                )

                AboutSettingsSection()
            }
            .padding(24)
            .frame(
                minWidth: 520,
                idealWidth: 680,
                maxWidth: 760,
                alignment: .leading
            )
        }
        .navigationTitle("Settings")
    }
}
