// GeneralSettingsSection.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - GeneralSettingsSection

/// Reusable general-settings section extracted from `SettingsView+Sections`.
///
/// Owns the launch-at-login toggle and reads/writes `LoginItem`.
/// The notification-preference row is intentionally absent: it controls
/// menu-bar-popover behaviour that does not apply to the windowed destination.
///
/// ## Layout
/// The outer section title is provided by `MigrationSettingsSectionLayout`.
/// This view renders the "Startup" group heading and one card row.
struct GeneralSettingsSection: View {

    /// Whether RunBot is registered as a Login Item.
    @State private var launchAtLogin = LoginItem.isEnabled

    // MARK: - Body

    /// Group heading + launch-at-login card.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Startup")
                .font(.system(size: 15, weight: .semibold))

            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Launch at login")
                        .font(.system(size: 15, weight: .medium))

                    Text("Automatically launch RunBot when you log in.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 24)

                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .tint(Color.rbSuccess)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { _, newVal in
                        applyLaunchAtLogin(newVal)
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .frame(minHeight: 72)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.rbSettingsCardBackground)
            )
        }
    }

    /// Writes the Login Item entry then re-reads state so the toggle snaps on failure.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
    }
}
