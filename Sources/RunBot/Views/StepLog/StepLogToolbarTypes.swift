// StepLogToolbarTypes.swift
// RunBot

import SwiftUI

// MARK: - LogPresentation

/// Segmented-picker cases for the step-log format selector. (#2911)
enum LogPresentation: String, CaseIterable, Identifiable {
    /// Raw ANSI coloured log output.
    case ansi
    /// Rendered Markdown view.
    case markdown

    /// Stable identity for `ForEach`.
    var id: Self { self }

    /// Display label shown inside the segmented control.
    var title: String {
        switch self {
        case .ansi: return "ANSI"
        case .markdown: return "Markdown"
        }
    }
}

// MARK: - StepLogActionButtonStyle

/// Applies the shared bordered-small treatment to step-log action buttons. (#2911)
struct StepLogActionButtonStyle: ViewModifier {
    /// Applies `.bordered` + `.small` + 13-pt medium font.
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .medium))
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

/// Convenience modifier for step-log toolbar action buttons.
extension View {
    /// Applies `StepLogActionButtonStyle` - matches the Add scope bordered treatment.
    func stepLogActionStyle() -> some View {
        modifier(StepLogActionButtonStyle())
    }
}
