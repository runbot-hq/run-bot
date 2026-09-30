// EnvironmentTokenCard.swift
// RunBot

import GitHubClient
import SwiftUI

// MARK: - EnvironmentTokenCard

/// Settings row for the environment-token authentication source.
///
/// Full-width row layout matching the standard settings card pattern (#2892).
/// The background fill comes from `AuthenticationSourceCard`.
///
/// Interaction rules from #2459 §4.5:
/// - Toggle **on**  → selects environment even when token is missing (shows inline error).
/// - Toggle **off** → selects OAuth if signed in; otherwise app becomes unauthenticated.
struct EnvironmentTokenCard: View {

    /// Current environment token discovery state.
    let envState: EnvironmentTokenState
    /// Whether the environment token source is the user’s currently-selected source.
    let isActive: Bool
    /// When `true`, the toggle is disabled and dimmed.
    let isDisabled: Bool
    /// Called when the toggle is flipped. `true` means the user wants env token active.
    let onToggle: (Bool) -> Void

    // MARK: - Derived

    /// `true` when the card is active but the token is missing — shows red styling.
    private var isError: Bool {
        isActive && envState == .unavailable
    }

    // MARK: - Body

    /// Full-width row: label block on the left, toggle on the right.
    var body: some View {
        AuthenticationSourceCard(isActive: isActive, isError: isError) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        statusDot
                        Text("Environment Token")
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                    }
                    statusLine
                        .font(.system(size: 13))
                        .foregroundStyle(isError ? Color.rbDanger : Color.rbTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(isActive ? 1.0 : 0.75)

                Spacer(minLength: 24)

                Toggle("", isOn: Binding(
                    get: { isActive },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.35 : isActive ? 1.0 : 0.65)
                .help(isDisabled ? "Turn off GitHub OAuth before enabling environment token" : "")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValueText)
    }

    // MARK: - Sub-views

    /// Animated dot (or spinner) reflecting the current `envState`.
    @ViewBuilder
    private var statusDot: some View {
        switch envState {
        case .checking:
            ProgressView().scaleEffect(0.5).frame(width: 7, height: 7)
        case .unavailable:
            Circle().fill(isActive ? Color.rbDanger : Color.rbTextTertiary)
                .frame(width: 7, height: 7)
        case .available:
            Circle().fill(isActive ? Color.rbSuccess : Color.rbTextSecondary)
                .frame(width: 7, height: 7)
        }
    }

    /// Status description text below the title.
    private var statusLine: some View {
        Group {
            switch envState {
            case .checking:
                Text("Checking…")
            case .unavailable:
                if isActive {
                    Text("Enabled · GH_TOKEN or GITHUB_TOKEN not found")
                } else {
                    Text("GH_TOKEN or GITHUB_TOKEN not found")
                }
            case .available:
                if isActive {
                    Text("Active · authenticated via environment token")
                } else {
                    Text("Available · not in use")
                }
            }
        }
    }

    /// VoiceOver value string combining source name, active state, and token status.
    private var accessibilityValueText: String {
        let source = "Environment token"
        let activeText = isActive ? "enabled" : "disabled"
        switch envState {
        case .checking: return "\(source), \(activeText), checking"
        case .unavailable: return "\(source), \(activeText), token not found"
        case .available: return "\(source), \(activeText), token found"
        }
    }
}
