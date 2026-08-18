// LogCopyButton.swift
// RunBot
import AppKit
import RunBotCore
import SwiftUI

/// Top-bar copy button shared by ActionDetailView, JobDetailView, and StepLogView.
/// States: idle -> loading -> done (1.5 s) or failed (1.5 s) -> idle.
struct LogCopyButton: View {
    /// Callback-based fetch. Invoke `completion` with the log text on success,
    /// or `nil` / empty string on failure -- button resets to idle either way.
    let fetch: (@escaping @Sendable (String?) -> Void) -> Void
    /// When `true` the button is rendered at reduced opacity and cannot be tapped.
    var isDisabled: Bool = false

    /// Current visual phase of the copy lifecycle.
    @State private var phase: Phase = .idle

    /// Visual states of the copy button lifecycle.
    enum Phase {
        /// Normal tappable state showing "Copy log".
        case idle
        /// Spinner shown while fetching log text.
        case loading
        /// Green checkmark shown for 1.5 s after a successful copy.
        case done
        /// Red cross shown for 1.5 s after a failed fetch.
        case failed
    }

    /// Renders the button in its current phase (idle, loading, done, or failed).
    var body: some View {
        Group {
            switch phase {
            case .idle:
                Button(action: startCopy) {
                    Label("Copy log", systemImage: "doc.on.doc")
                }
                .font(.system(size: 13, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.4 : 1)
            case .loading:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Copying…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
            case .done:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text("Done")
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

    /// Initiates the fetch, transitions to `.loading`, then resolves to `.done` or `.failed`.
    private func startCopy() {
        guard phase == .idle else { return }
        phase = .loading
        fetch { copyText in
            Task { @MainActor in
                if let text = copyText, !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    phase = .done
                } else {
                    phase = .failed
                }
                // try? intentionally swallows CancellationError -- phase = .idle
                // runs unconditionally so the button is always reusable after the
                // 1.5 s window, even if the view is dismissed mid-flight.
                try? await Task.sleep(for: .milliseconds(1500))
                phase = .idle
            }
        }
    }
}
