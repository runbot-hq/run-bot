// PanelHeaderView.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - PanelHeaderView
/// Top bar of the popover panel showing system stats and the settings/quit buttons.
struct PanelHeaderView: View {
    /// View model driving the CPU/MEM/disk stat pills.
    var statsVM: SystemStatsViewModel
    /// Called when the user taps the settings gear button.
    let onSelectSettings: () -> Void

    /// Renders the header HStack with stats bar and settings/quit buttons.
    var body: some View {
        HStack(spacing: 6) {
            HeaderStatsBar(statsVM: statsVM)
            Spacer()
            if #available(macOS 26, *) {
                HStack(spacing: 8) {
                    GlassEffectContainer { settingsButton.glassButton() }
                    GlassEffectContainer { quitButton.glassButton() }
                }
            } else {
                settingsButton
                quitButton
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Settings gear button — plain style, 28 pt hit area.
    @ViewBuilder private var settingsButton: some View {
        Button(action: onSelectSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    /// Quit button — plain style, 28 pt hit area.
    @ViewBuilder private var quitButton: some View {
        Button(action: { NSApplication.shared.terminate(nil) }) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Quit RunBot")
        .accessibilityLabel("Quit RunBot")
    }
}

// MARK: - SectionHeaderLabel
/// Uppercase small-caps label used as a section divider inside the panel.
struct SectionHeaderLabel: View {
    /// The raw title string; displayed uppercased.
    let title: String

    /// Renders the uppercased title with section-caption font and secondary colour.
    var body: some View {
        Text(title.uppercased())
            .font(RBFont.sectionCaption)
            .foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}
