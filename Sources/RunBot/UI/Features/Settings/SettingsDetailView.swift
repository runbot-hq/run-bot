// SettingsDetailView.swift
// RunBot

import AppUpdater
import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - SettingsDetailView

/// Detail column for the settings destination.
///
/// Wraps the selected section in a `ScrollView` so Authentication,
/// Updates, and future tall sections remain accessible in short windows.
/// Width is capped at 820 points for readability.
///
/// ## Card layering rule
/// Each shared section view owns exactly one card surface. This view must
/// not apply an additional outer `settingsCard()` around the routed
/// content — doing so creates a double-background (outer neutral card wrapping
/// the inner styled card). The `SettingsSectionLayout` provides the
/// section title and spacing only.
///
/// ## Authentication
/// `AuthenticationSection` owns its two source cards. No section-level card
/// wrapper is added here.
///
/// ## Dependency rules
/// - `GitHubAuthentication` is read from the environment (owned by
///   `RunBotApp`). No second instance is created here.
/// - `onToggleEnvironment` selects `.environment`, `.oauth` (when signed in),
///   or `.unauthenticated` to match main's toggle logic.
/// - A `.task` on `AuthenticationSection` runs `refreshAuthentication()` once
///   on mount so `environmentState` exits `.checking`.
///
/// ## SIZING CONTRACT — condensed from the pre-AppShell SettingsView guards
/// The popover-era `SettingsView` carried a WIDTH/HEIGHT CONTRACT block built
/// from several layout regressions. The constraints that still apply here:
///
/// - The `maxWidth: 820` cap in `body` is LOAD-BEARING for readability.
///   ❌ Do not remove it — detail content then stretches to the full window
///   width. ❌ Do not replace it with `.frame(idealWidth:)` — idealWidth is a
///   preference, not a constraint, and is ignored when the parent offers more.
/// - ❌ Do not wrap this view's root `ScrollView` in a GeometryReader to
///   measure it — measurement has exactly one owner (see the SIZING CONTRACT
///   on `AppNavigationSplitView`). Measuring here reintroduces the multi-source
///   disagreement that caused #2278/#2279 and the side-jump family (#375–377).
/// - `.fixedSize(horizontal: false, vertical: true)` on multi-line rows in
///   the section views (Updates, General, Authentication cards) is
///   LOAD-BEARING inside a ScrollView: without it, text views under-report
///   their height (the old "height-inheritance" regression class — content
///   clipped instead of growing).
@MainActor
struct SettingsDetailView: View {

    // MARK: - Environment

    /// The active GitHub authentication state, injected from the environment.
    @Environment(GitHubAuthentication.self)
    private var authentication

    // MARK: - Inputs

    /// The section currently selected in the list pane.
    let selection: SettingsSection?

    /// Services required by the settings sections.
    let dependencies: SettingsDependencies

    // MARK: - Body

    /// Scrollable detail view with breathing-room padding and readable-width cap.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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

    /// Routes the selected section to the appropriate settings view.
    ///
    /// Each case uses `SettingsSectionLayout` for the section title
    /// and vertical spacing only. The section view itself is responsible for
    /// its own card surface — no outer card is applied here.
    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .authentication {
        case .authentication:
            SettingsSectionLayout(title: "Authentication") {
                AuthenticationSection(
                    authentication: authentication,
                    onSignIn: dependencies.onSignIn,
                    onSignOut: { Task { await dependencies.onSignOut() } },
                    onToggleEnvironment: { enabled in
                        if enabled {
                            authentication.setSelectedSource(.environment)
                        } else if case .signedIn = authentication.oauthState {
                            authentication.setSelectedSource(.oauth)
                        } else {
                            authentication.setSelectedSource(.unauthenticated)
                        }
                    }
                )
                .task {
                    await dependencies.refreshAuthentication()
                }
            }
        case .general:
            SettingsSectionLayout(title: "General") {
                GeneralSettingsSection(
                    notifications: dependencies.notifications
                )
            }
        case .updates:
            SettingsSectionLayout(title: "Updates") {
                VStack(alignment: .leading, spacing: 28) {
                    UpdateSettingsSection(
                        settings: dependencies.settings,
                        runnerState: dependencies.runnerState,
                        autoUpdater: dependencies.autoUpdater
                    )

                    AboutSettingsSection()
                }
            }
        }
    }
}
