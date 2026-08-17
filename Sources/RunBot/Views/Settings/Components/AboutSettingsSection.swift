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
struct AboutSettingsSection: View {

    // MARK: - Version

    /// The marketing version string from `Bundle.main.rbVersionString`.
    private var appVersion: String { Bundle.main.rbVersionString }
    /// The build number from `CFBundleVersion`.
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    // MARK: - Body

    /// The about section card showing version, build, and pre-release badge.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("About")
                .font(RBFont.sectionHeader)
                .foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md)
                .padding(.top, 8)
                .padding(.bottom, 4)

            HStack {
                Text("RunBot").font(.system(size: 12))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(appVersion) (\(appBuild))")
                        .font(.system(size: 12))
                        .foregroundColor(Color.rbTextSecondary)
                    if Bundle.main.isPreReleaseBuild {
                        Text("Pre-release build")
                            .font(.caption2)
                            .foregroundColor(Color.rbTextTertiary)
                    }
                }
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, 5)
        }
        .background(
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(Color.rbSettingsCardBackground)
    )
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 8)
    }
}
