// CopyLinkButton.swift
// RunBot
import AppKit
import SwiftUI

/// Top-bar copy-link button for GitHub URLs.
/// States: idle -> done (1.5 s) or failed (1.5 s) -> idle.
///
/// - Note: `url` is expected to be non-empty. At the StepLogView call site this
///   is guaranteed by the enclosing `if let urlString = job.htmlUrl` guard —
///   do NOT move this button outside that guard without adding nil/empty handling.
struct CopyLinkButton: View {
    /// URL string to copy to the system pasteboard.
    let url: String

    /// Current visual phase of the copy lifecycle.
    @State private var phase: Phase = .idle
    /// Stored handle for the in-flight reset task; cancelled in `onDisappear`
    /// so the task does not outlive the view (matches `StepLogView.loadTask` pattern).
    @State private var resetTask: Task<Void, Never>?

    /// Visual states of the copy button lifecycle.
    enum Phase {
        /// Normal tappable state showing "Copy link".
        case idle
        /// Green checkmark shown for 1.5 s after a successful copy.
        case done
        /// Red cross shown for 1.5 s after a failed copy.
        case failed
    }

    /// Renders the button in its current phase (idle, done, or failed).
    ///
    /// A single `Button` wraps all phases so the control remains in the
    /// accessibility tree throughout the feedback cycle. The button is
    /// disabled (not replaced) in `.done`/`.failed` so VoiceOver always
    /// sees a consistent element and users can retry immediately after
    /// `.failed` once `.idle` is restored.
    var body: some View {
        Button(action: copy) {
            Group {
                switch phase {
                case .idle:
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption)
                        Text("Copy link")
                            .font(.caption)
                            .fixedSize()
                    }
                    .foregroundColor(.secondary)
                case .done:
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundColor(Color.rbSuccess)
                        Text("Copied")
                            .font(.caption)
                            .foregroundColor(Color.rbSuccess)
                            .fixedSize()
                    }
                case .failed:
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(Color.rbDanger)
                        Text("Failed")
                            .font(.caption)
                            .foregroundColor(Color.rbDanger)
                            .fixedSize()
                    }
                }
            }
        }
        .disabled(phase != .idle)
        .buttonStyle(.plain)
        .help("Copy GitHub job URL")
        .accessibilityLabel("Copy link")
        .onDisappear {
            // Cancel the reset task and immediately return to .idle so the
            // button is never stuck in .done/.failed if this view instance is
            // reused without an .id() identity change on re-navigation.
            resetTask?.cancel()
            resetTask = nil
            phase = .idle
        }
    }

    /// Copies `url` to the system pasteboard and transitions to `.done` or `.failed`,
    /// then resets to `.idle` after 1.5 s. Cancels any in-flight reset task before
    /// spawning a new one.
    ///
    /// `clearContents()` is intentionally omitted: `setString(_:forType:)` replaces
    /// pasteboard contents atomically on success. Calling `clearContents()` first
    /// would destroy the user's existing clipboard even when `setString` subsequently
    /// fails, which is user-hostile and was the pre-existing bug.
    private func copy() {
        guard phase == .idle else { return }
        let ok = NSPasteboard.general.setString(url, forType: .string)
        phase = ok ? .done : .failed
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            phase = .idle
        }
    }
}
