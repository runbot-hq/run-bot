// PanelHeaderView.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - PanelHeaderView
/// Top bar of the popover panel showing system stats and the settings/quit buttons.
struct PanelHeaderView: View {
    /// View model driving the CPU/GPU/MEM/disk stat pills.
    var statsVM: SystemStatsViewModel
    /// Called when the user taps the settings gear button.
    let onSelectSettings: () -> Void

    /// Renders the header HStack with stats bar and settings/quit buttons.
    /// The stats bar fills all remaining width after the separator and fixed-size control group.
    /// Outer horizontal padding is owned here and must not be duplicated inside HeaderStatsBar.
    var body: some View {
        HStack(spacing: RBSpacing.xs) {
            HeaderStatsBar(statsVM: statsVM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            headerSeparator
            HStack(spacing: 6) {
                GlassEffectContainer { settingsButton.glassButton() }
                GlassEffectContainer { quitButton.glassButton() }
            }
            .fixedSize()
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Vertical separator shared between metric chips and the DISK|Settings boundary.
    /// Matches the CPU|MEM and MEM|DISK separators inside HeaderStatsBar.
    private var headerSeparator: some View {
        Color.secondary
            .opacity(0.3)
            .frame(width: 1, height: 14)
            .fixedSize()
    }

    /// Settings gear button — plain style, 24 pt hit area.
    @ViewBuilder private var settingsButton: some View {
        Button(action: onSelectSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    /// Quit button — plain style, 24 pt hit area.
    @ViewBuilder private var quitButton: some View {
        Button(action: { NSApplication.shared.terminate(nil) }) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
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
