// LocalRunnerRowView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - LocalRunnerRowView

/// Reusable row for a single configured local runner with start/stop and delete controls.
///
/// Extracted from `LocalRunnersView` for reuse in the migration two-pane layout.
/// Toggle and delete taps do not propagate to `onSelect`.
struct LocalRunnerRowView: View {

    // MARK: - Inputs

    let runner: RunnerModel
    let onSelect: () -> Void
    let onSetRunning: (Bool) -> Void
    let onDelete: () -> Void

    // MARK: - Body

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Circle()
                    .fill(runner.statusColor.color)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(runner.runnerName)
                        .font(.system(size: 13))
                        .lineLimit(1)

                    if let url = runner.gitHubUrl {
                        Text(url.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { runner.isRunning },
                        set: { onSetRunning($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.rbSuccess)
                .scaleEffect(0.8, anchor: .trailing)
                .buttonStyle(.borderless)

                Button(
                    action: onDelete,
                    label: {
                        Image(systemName: "minus.circle")
                            .font(.caption2)
                            .foregroundStyle(Color.rbDanger)
                    }
                )
                .buttonStyle(.plain)
                .help("Remove runner")
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 5)
    }
}
