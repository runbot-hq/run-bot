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

    @State private var launchAtLogin = LoginItem.isEnabled

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
            .settingsTintedGlassCard(color: .rbAccent, cornerRadius: 8)
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, 8)
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
    }
}
