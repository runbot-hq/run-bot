// GeneralSettingsSection.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - GeneralSettingsSection

/// Reusable general-settings section extracted from `SettingsView+Sections`.
///
/// Owns the notification-mode picker and the launch-at-login toggle.
/// Both rows share one filled, borderless card with a subtle internal divider.
///
/// ## Layout
/// The outer section title is provided by `SettingsSectionLayout`.
/// This view renders the “Startup” group heading and one two-row card.
///
/// ## Notifications
/// The picker binds to `NotificationPreferences.shared` (passed in as
/// `notifications`). The same singleton is consumed by `RunnerPoller`, so
/// the picker and delivery always agree. See issue #2893.
struct GeneralSettingsSection: View {

    // MARK: - Inputs

    /// Notification delivery preferences. Must be `NotificationPreferences.shared`
    /// so the Settings picker and the poller read the same object.
    @Bindable var notifications: NotificationPreferences

    /// Whether RunBot is registered as a Login Item.
    @State private var launchAtLogin = LoginItem.isEnabled

    // MARK: - Body

    /// Group heading + two-row settings card.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Startup")
                .font(.system(size: 15, weight: .semibold))

            VStack(spacing: 0) {
                notificationsRow
                    .frame(minHeight: 72)

                Divider()
                    .opacity(0.10)
                    .padding(.leading, 20)

                launchAtLoginRow
                    .frame(minHeight: 72)
            }
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.rbSettingsCardBackground)
            )
        }
    }

    // MARK: - Rows

    /// Picker row controlling which workflow results trigger a macOS notification.
    ///
    /// This restores the row hidden for #2712/#2713; the underlying
    /// `UNUserNotificationCenter` delivery path is unchanged.
    private var notificationsRow: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notifications")
                    .font(.system(size: 15, weight: .medium))

                Text("Choose when to receive workflow status notifications.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 24)

            Picker("Notifications", selection: $notifications.notificationMode) {
                ForEach(NotificationMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    /// Toggle row controlling whether RunBot is a Login Item.
    private var launchAtLoginRow: some View {
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
    }

    // MARK: - Helpers

    /// Writes the Login Item entry then re-reads state so the toggle snaps on failure.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
    }
}
