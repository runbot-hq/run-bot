// AboutSettingsSection.swift
// RunBot

import SwiftUI

// MARK: - AboutSettingsSection

/// Reusable About section showing the canonical app version and build.
///
/// Uses `Bundle.main.rbVersionString` and `CFBundleVersion` — the same
/// sources as `SettingsView+Sections.aboutSection`. Do not hardcode a version.
///
/// The pre-release caption is driven by `Bundle.main.isPreReleaseBuild`
/// (see `Bundle+Version.swift`) rather than an inline `contains("-")` check,
/// to keep detection logic in one place. See PR #2085 / #2108.
///
/// ## Layout
/// The outer section title is provided by `MigrationSettingsSectionLayout`.
/// This view renders the "Version" group heading and one card row.
struct AboutSettingsSection: View {

    // MARK: - Version

    /// The marketing version string from `Bundle.main.rbVersionString`.
    private var appVersion: String { Bundle.main.rbVersionString }
    /// The build number from `CFBundleVersion`.
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    // MARK: - Body

    /// Group heading + version card.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Version")
                .font(.system(size: 15, weight: .semibold))

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RunBot")
                        .font(.system(size: 15, weight: .medium))

                    Text("Application version")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(appVersion) (\(appBuild))")
                        .font(.system(size: 14, weight: .medium))

                    if Bundle.main.isPreReleaseBuild {
                        Text("Pre-release build")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(minHeight: 76)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.rbSettingsCardBackground)
            )
        }
    }
}
