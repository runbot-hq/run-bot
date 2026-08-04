// EnvironmentTokenCard.swift
// RunBot

import GitHubClient
import SwiftUI

// MARK: - EnvironmentTokenCard

/// Settings card for the environment-token authentication source.
///
/// Shows the current `EnvironmentTokenState` and lets the user toggle the
/// environment token on/off. Implements the interaction rules from #2459 §4.5:
///
/// - Toggle **on**  → selects environment even when token is missing (shows inline error).
/// - Toggle **off** → selects OAuth if signed in; otherwise app becomes unauthenticated.
struct EnvironmentTokenCard: View {

    /// Current environment token discovery state.
    let envState: EnvironmentTokenState
    /// Whether the environment token source is the user's currently-selected source.
    let isActive: Bool
    /// When `true`, the toggle is disabled and dimmed.
    ///
    /// Set to `true` when the OAuth card is the active source so the two cards are
    /// mutually exclusive: the user must explicitly turn OAuth off before enabling env.
    let isDisabled: Bool
    /// Called when the toggle is flipped. `true` means the user wants env token active.
    let onToggle: (Bool) -> Void

    // MARK: - Derived

    /// Name of the discovered env variable, or `nil` when unavailable/checking.
    private var tokenVariableName: String? {
        guard case .available(let variable) = envState else { return nil }
        switch variable {
        case .ghToken: return "GH_TOKEN"
        case .githubToken: return "GITHUB_TOKEN"
        }
    }

    /// `true` when the card is active but the token is missing — shows red styling.
    private var isError: Bool {
        isActive && envState == .unavailable
    }

    // MARK: - Body

    /// Card body: status dot, label, and on/off toggle.
    var body: some View {
        AuthenticationSourceCard(isActive: isActive, isError: isError) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        statusDot
                        Text("Environment Token")
                            .font(.system(size: 12, weight: .medium))
                    }
                    statusLine
                        .font(.caption)
                        .foregroundColor(isError ? Color.rbDanger : Color.rbTextSecondary)
                }
                .opacity(isActive ? 1.0 : 0.75)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isActive },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.8)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.35 : isActive ? 1.0 : 0.65)
                .help(isDisabled ? "Turn off GitHub OAuth before enabling environment token" : "")
            }
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

    /// One-line status text below the title.
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
            case .available(let variable):
                let name = variable == .ghToken ? "GH_TOKEN" : "GITHUB_TOKEN"
                if isActive {
                    Text("Active · authenticated via \(name)")
                } else {
                    Text("Available · not in use (\(name))")
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
        case .available(let variable):
            let name = variable == .ghToken ? "GH_TOKEN" : "GITHUB_TOKEN"
            return "\(source), \(activeText), \(name) found"
        }
    }
}
