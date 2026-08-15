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
struct UpdateSettingsSection: View {

    /// App-wide preference store — needs @Bindable for two-way toggle bindings.
    @Bindable var settings: AppPreferencesStore
    /// Observable runner state — read to drive the update action row.
    let runnerState: RunnerState
    /// The shared auto-updater; must be owned at the composition root.
    let autoUpdater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Updates")
                .font(RBFont.sectionHeader)
                .foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md)
                .padding(.top, 8)
                .padding(.bottom, 4)

            VStack(spacing: 0) {
                automaticUpdatesRow
                if settings.automaticUpdatesEnabled {
                    Divider().padding(.leading, RBSpacing.md)
                    betaChannelRow
                }
                if settings.automaticUpdatesEnabled && runnerState.currentPhase != .idle {
                    Divider().padding(.leading, RBSpacing.md)
                    GlassEffectContainer {
                        updateActionRow
                    }
                }
            }
            .settingsTintedGlassCard(color: .rbAccent, cornerRadius: 8)
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Rows

    private var automaticUpdatesRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic updates").font(.system(size: 12))
                Text("Automatically downloads updates from GitHub Releases, verified with Ed25519.")
                    .font(.caption2).foregroundColor(Color.rbTextSecondary)
            }
            Spacer()
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
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 6)
    }

    private var betaChannelRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Beta channel").font(.system(size: 12))
                Text("Receive pre-release builds when checking for updates. Does not affect your currently installed version.")
                    .font(.caption2).foregroundColor(Color.rbTextSecondary)
            }
            Spacer()
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
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var updateActionRow: some View {
        HStack {
            switch runnerState.currentPhase {
            case .idle:
                EmptyView()
            case .available(let version):
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available: \(version)").font(.system(size: 12))
                    Text("A new version is available. Click to download and install.")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
                Button("Install & Relaunch") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(true)
            case .downloading(let version):
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available: \(version)").font(.system(size: 12))
                    ProgressView("Downloading update…")
                        .scaleEffect(RBMetrics.updateProgressScale)
                }
                Spacer()
            case .ready(let version):
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available: \(version)").font(.system(size: 12))
                    Text("A new version of the app is ready to be installed.")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
                Button("Install & Relaunch") {
                    Task { await autoUpdater.installAndRelaunch(state: runnerState) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Install and relaunch RunBot")
            case .failed(let version):
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available" + (version.map { ": \($0)" } ?? ""))
                        .font(.system(size: 12))
                    Text("Download failed. Check your connection and try again.")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
                Button("Retry") {
                    Task { await autoUpdater.checkAndHandle(state: runnerState) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
    }
}
