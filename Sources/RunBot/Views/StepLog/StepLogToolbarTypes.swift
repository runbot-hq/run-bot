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

// MARK: - LogPresentationControl

/// Joined two-segment format selector for the step-log detail view. (#2914)
///
/// Uses a custom container so both segments share one outer rounded boundary
/// and a single centre divider, giving the classic joined-segment appearance.
struct LogPresentationControl: View {
    /// The currently active presentation mode.
    @Binding var selection: LogPresentation

    /// Renders ANSI and Markdown segments inside a shared rounded container.
    var body: some View {
        HStack(spacing: 0) {
            segment(.ansi)

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1)

            segment(.markdown)
        }
        .frame(height: 28)
        .background(Color.primary.opacity(0.06))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    /// Builds one labelled segment button.
    private func segment(_ presentation: LogPresentation) -> some View {
        Button {
            selection = presentation
        } label: {
            Text(presentation.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    selection == presentation
                        ? Color.white
                        : Color.secondary
                )
                .frame(
                    minWidth: presentation == .ansi ? 68 : 92,
                    minHeight: 28
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if selection == presentation {
                Color.accentColor
            }
        }
        .accessibilityAddTraits(selection == presentation ? .isSelected : [])
    }
}
