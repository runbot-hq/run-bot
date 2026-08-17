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
struct GeneralSettingsSection: View {

    /// Whether RunBot is registered as a Login Item.
    @State private var launchAtLogin = LoginItem.isEnabled

    /// The launch-at-login settings card.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General")
                .font(RBFont.sectionHeader)
                .foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md)
                .padding(.top, 8)
                .padding(.bottom, 4)

            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login").font(.system(size: 12))
                        Text("Automatically launch RunBot when you log in.")
                            .font(.caption2)
                            .foregroundColor(Color.rbTextSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .tint(Color.rbSuccess)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, newVal in
                            applyLaunchAtLogin(newVal)
                        }
                }
                .padding(.horizontal, RBSpacing.md)
                .padding(.vertical, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.rbSettingsCardBackground)
            )
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, 8)
        }
    }

    /// Writes the Login Item entry then re-reads state so the toggle snaps on failure.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
    }
}
