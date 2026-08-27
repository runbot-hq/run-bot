// RemovalAlertModifier.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - RemovalAlertModifier

/// Confirmation alert for runner removal.
/// Presents a destructive action sheet with Cancel and Remove buttons.
/// `onConfirm` is called on destructive confirmation; `onCancel` on dismissal.
/// The `isAuthenticated` flag selects between two pre-composed message strings
/// defined inside this modifier — only the flag itself is caller-supplied.
struct RemovalAlertModifier: ViewModifier {
    /// The alert title string.
    let title: String
    /// Controls whether the alert is presented.
    @Binding var isPresented: Bool
    /// Whether a GitHub token is available; selects the pre-composed message text.
    let isAuthenticated: Bool
    /// Called when the user taps Cancel.
    let onCancel: () -> Void
    /// Called when the user confirms removal.
    let onConfirm: () -> Void

    /// Wraps `content` with a runner-removal confirmation alert.
    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            Button("Cancel", role: .cancel) { onCancel() }
            Button("Remove", role: .destructive) { onConfirm() }
        } message: {
            if isAuthenticated {
                Text("This will run ./svc.sh uninstall and ./config.sh remove. "
                        + "A GitHub token is required for de-registration.")
            } else {
                // Note: gh auth login is no longer a supported auth path (removed in Batch 18 GitHubTokenCache.swift).
                // Direct users to Settings OAuth flow or the GH_TOKEN / GITHUB_TOKEN env vars instead.
                Text("A GitHub token is required to de-register the runner from GitHub. "
                        + "Sign in via Settings or set GH_TOKEN / GITHUB_TOKEN env var, then try again.")
            }
        }
    }
}
