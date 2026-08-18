// MigrationRunnerDetailView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - MigrationRunnerDetailView

/// Detail-column view for the Local Runners section.
///
/// Uses the same visual language as the Settings detail pages:
/// a large page title, compact section headings, rounded filled cards,
/// left-aligned labels, trailing values, and subtle inset separators.
/// Replaces the older `RunnerDetailContentView` delegation. (#2904)
struct MigrationRunnerDetailView: View {

    // MARK: - Inputs

    /// The runner whose detail should be displayed, or `nil` when nothing is selected.
    let runner: RunnerModel?

    // MARK: - Async display fields

    /// OS and architecture string loaded asynchronously from the runner JSON file.
    @State private var displayOsArch: String = ""
    /// Agent version string loaded asynchronously from the runner JSON file.
    @State private var displayVersion: String = ""

    // MARK: - Body

    /// Shows the Settings-style detail layout when a runner is selected,
    /// otherwise a centred placeholder.
    var body: some View {
        if let runner {
            detailBody(runner)
        } else {
            MigrationColumnPlaceholder(
                title: "Select a local runner",
                systemImage: "desktopcomputer"
            )
        }
    }

    // MARK: - Detail body

    /// Full Settings-style detail layout for a resolved runner.
    @ViewBuilder
    private func detailBody(_ runner: RunnerModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(runner.runnerName)
                    .font(.title2.weight(.semibold))

                runnerInformationSection(runner)
                configurationSection(runner)
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: 820, alignment: .topLeading)
        }
        .task(id: runner.id) { await loadDisplayFields(for: runner) }
    }

    // MARK: - Sections

    /// 'Runner information' card section.
    private func runnerInformationSection(_ runner: RunnerModel) -> some View {
        detailSection(title: "Runner information") {
            if let url = runner.gitHubUrl {
                copyableDetailRow(
                    title: "GitHub URL",
                    description: "Repository or organization this runner is registered with.",
                    value: url.absoluteString
                )
                rowDivider()
            }
            detailRow(
                title: "Work folder",
                description: "Directory used to store workflow files and job data.",
                value: runner.workFolder ?? "_work"
            )
            rowDivider()
            detailRow(
                title: "Ephemeral",
                description: "Automatically unregisters after completing one job.",
                value: runner.isEphemeral ? "Yes" : "No"
            )
            if !displayOsArch.isEmpty {
                rowDivider()
                detailRow(
                    title: "OS / Arch",
                    description: "Operating system and processor architecture.",
                    value: displayOsArch
                )
            }
            if !displayVersion.isEmpty {
                rowDivider()
                detailRow(
                    title: "Version",
                    description: "Installed GitHub Actions runner version.",
                    value: displayVersion
                )
            }
            rowDivider()
            detailRow(
                title: "Status",
                description: "Current availability reported by the runner.",
                value: runner.displayStatus
            )
        }
    }

    /// 'Configuration' card section.
    private func configurationSection(_ runner: RunnerModel) -> some View {
        detailSection(title: "Configuration") {
            detailRow(
                title: "Labels",
                description: "Used by workflows to target this runner.",
                value: runner.labels.isEmpty ? "—" : runner.labels.joined(separator: ", ")
            )
            rowDivider()
            detailRow(
                title: "Group",
                description: "Controls which repositories can use this runner.",
                value: runner.runnerGroup ?? "—"
            )
        }
    }

    // MARK: - Layout helpers

    /// Rounded filled card with a compact section heading above it.
    private func detailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.rbSettingsCardBackground)
            )
        }
    }

    /// Standard label / description / value row.
    private func detailRow(title: String, description: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 24)

            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(minHeight: 72)
}

    /// Label / description / value row with an inline copy button; used for the GitHub URL.
    private func copyableDetailRow(title: String, description: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 24)

            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy to clipboard")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(minHeight: 72)
}

    /// Subtle inset separator placed between rows inside a card.
    ///
    /// Uses an explicitly coloured 1-pt `Rectangle` rather than a system
    /// `Divider` so the final opacity is predictable against the card background.
    private func rowDivider() -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, 20)
    }

    // MARK: - Async loader

    /// Reads OS/arch and version from the runner JSON file and updates display state.
    @MainActor
    private func loadDisplayFields(for runner: RunnerModel) async {
        displayOsArch = ""
        displayVersion = ""
        guard let installPath = runner.installPath else { return }
        var draft = RunnerEditDraft(runner: runner)
        let config = await draft.load(
            installPath: installPath,
            configStore: RunnerConfigStore.shared,
            proxyStore: RunnerProxyStore.shared
        )
        guard let config else { return }
        let combined = [config.platform, config.platformArchitecture]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        if !combined.isEmpty { displayOsArch = combined }
        if let version = config.agentVersion, !version.isEmpty { displayVersion = version }
    }
}
