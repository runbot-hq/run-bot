// UpdateSettingsSection.swift
// RunBot

import AppUpdater
import RunBotCore
import SwiftUI

// MARK: - UpdateSettingsSection

/// Reusable update-settings section extracted from `SettingsView+Sections`.
///
/// Renders:
/// - Automatic updates toggle.
/// - Beta channel toggle (only when automatic updates are enabled).
/// - Update action row (only when a non-idle update phase is active).
///
/// The updater is injected so it is never instantiated inside this view.
/// Instantiate once at the composition root and thread through
/// `MigrationSettingsDependencies`.
///
/// ## Layout
/// The outer section title is provided by `MigrationSettingsSectionLayout`.
/// This view renders the "Update preferences" group heading and one multi-row card.
struct UpdateSettingsSection: View {

    /// App-wide preference store; needs `@Bindable` for two-way toggle bindings.
    @Bindable var settings: AppPreferencesStore
    /// Observable runner state — read to drive the update action row.
    let runnerState: RunnerState
    /// The shared auto-updater; must be owned at the composition root.
    let autoUpdater: AppUpdater

    // MARK: - Body

    /// Group heading + update settings card.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Update preferences")
                .font(.system(size: 15, weight: .semibold))

            VStack(spacing: 0) {
                automaticUpdatesRow
                    .frame(minHeight: 72)

                if settings.automaticUpdatesEnabled {
                    Divider()
                        .opacity(0.10)
                        .padding(.leading, 20)

                    betaChannelRow
                        .frame(minHeight: 72)
                }

                if settings.automaticUpdatesEnabled && runnerState.currentPhase != .idle {
                    Divider()
                        .opacity(0.10)
                        .padding(.leading, 20)

                    updateActionRow
                        .frame(minHeight: 68)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.rbSettingsCardBackground)
            )
        }
    }

    // MARK: - Rows

    /// Row toggling automatic update downloads.
    private var automaticUpdatesRow: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Automatic updates")
                    .font(.system(size: 15, weight: .medium))

                Text("Automatically downloads updates from GitHub Releases, verified with Ed25519.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 24)

            Toggle("", isOn: $settings.automaticUpdatesEnabled)
                .toggleStyle(.switch)
                .tint(Color.rbSuccess)
                .labelsHidden()
                .onChange(of: settings.automaticUpdatesEnabled) { _, enabled in
                    if enabled {
                        Task { await autoUpdater.checkAndHandle(state: runnerState) }
                    }
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Row toggling the beta update channel.
    private var betaChannelRow: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Beta channel")
                    .font(.system(size: 15, weight: .medium))

                Text("Receive pre-release builds when checking for updates. Does not affect your currently installed version.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 24)

            Toggle("", isOn: $settings.betaChannel)
                .toggleStyle(.switch)
                .tint(Color.rbSuccess)
                .labelsHidden()
                .onChange(of: settings.betaChannel) { _, _ in
                    if settings.automaticUpdatesEnabled {
                        Task { await autoUpdater.checkAndHandle(state: runnerState) }
                    }
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Row showing download progress or install action for a pending update.
    @ViewBuilder
    private var updateActionRow: some View {
        HStack(alignment: .center, spacing: 20) {
            switch runnerState.currentPhase {
            case .idle:
                EmptyView()
            case .available(let version):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update available: \(version)")
                        .font(.system(size: 15, weight: .medium))
                    Text("A new version is available. Click to download and install.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                Button("Install & Relaunch") {
                    // Intentionally empty: placeholder — button is disabled until
                    // install-and-relaunch wiring lands.
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(true)
            case .downloading(let version):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update available: \(version)")
                        .font(.system(size: 15, weight: .medium))
                    ProgressView("Downloading update…")
                        .scaleEffect(RBMetrics.updateProgressScale)
                }
                Spacer()
            case .ready(let version):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update available: \(version)")
                        .font(.system(size: 15, weight: .medium))
                    Text("A new version of the app is ready to be installed.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                Button("Install & Relaunch") {
                    Task { await autoUpdater.installAndRelaunch(state: runnerState) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Install and relaunch RunBot")
            case .failed(let version):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update available" + (version.map { ": \($0)" } ?? ""))
                        .font(.system(size: 15, weight: .medium))
                    Text("Download failed. Check your connection and try again.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                Button("Retry") {
                    Task { await autoUpdater.checkAndHandle(state: runnerState) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
