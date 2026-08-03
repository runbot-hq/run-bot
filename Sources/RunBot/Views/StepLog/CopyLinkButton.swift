// CopyLinkButton.swift
// RunBot
import AppKit
import SwiftUI

/// Top-bar copy-link button for GitHub URLs.
/// States: idle -> done (1.5 s) or failed (1.5 s) -> idle.
struct CopyLinkButton: View {
    /// URL string to copy to the system pasteboard.
    let url: String

    /// Current visual phase of the copy lifecycle.
    @State private var phase: Phase = .idle

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
    var body: some View {
        Group {
            switch phase {
            case .idle:
                Button(action: copy) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption)
                        Text("Copy link")
                            .font(.caption)
                            .fixedSize()
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy GitHub job URL")
            case .done:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text("Copied")
                        .font(.caption)
                        .foregroundColor(.green)
                        .fixedSize()
                }
            case .failed:
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundColor(.red)
                    Text("Failed")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize()
                }
            }
        }
    }

    /// Copies `url` to the system pasteboard and transitions to `.done` or `.failed`.
    private func copy() {
        guard phase == .idle else { return }
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(url, forType: .string)
        phase = ok ? .done : .failed
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            phase = .idle
        }
    }
}
