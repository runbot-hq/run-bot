// RunnerDetailView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - RunnerDetailView

/// Detail-column view for the Local Runners section.
///
/// Uses the same visual language as the Settings detail pages:
/// a large page title, compact section headings, rounded filled cards,
/// left-aligned labels, trailing values, and subtle inset separators.
/// Replaces the older `RunnerDetailContentView` delegation. (#2904)
struct RunnerDetailView: View {

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
            ColumnPlaceholder(
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
                migrationCopyableDetailRow(
                    title: "GitHub URL",
                    description: "Repository or organization this runner is registered with.",
                    value: url.absoluteString
                )
                migrationRowDivider()
            }
            migrationDetailRow(
                title: "Work folder",
                description: "Directory used to store workflow files and job data.",
                value: runner.workFolder ?? "_work"
            )
            migrationRowDivider()
            migrationDetailRow(
                title: "Ephemeral",
                description: "Automatically unregisters after completing one job.",
                value: runner.isEphemeral ? "Yes" : "No"
            )
            if !displayOsArch.isEmpty {
                migrationRowDivider()
                migrationDetailRow(
                    title: "OS / Arch",
                    description: "Operating system and processor architecture.",
                    value: displayOsArch
                )
            }
            if !displayVersion.isEmpty {
                migrationRowDivider()
                migrationDetailRow(
                    title: "Version",
                    description: "Installed GitHub Actions runner version.",
                    value: displayVersion
                )
            }
            migrationRowDivider()
            migrationDetailRow(
                title: "Status",
                description: "Current availability reported by the runner.",
                value: runner.displayStatus
            )
        }
    }

    /// 'Configuration' card section.
    private func configurationSection(_ runner: RunnerModel) -> some View {
        detailSection(title: "Configuration") {
            migrationDetailRow(
                title: "Labels",
                description: "Used by workflows to target this runner.",
                value: runner.labels.isEmpty ? "—" : runner.labels.joined(separator: ", ")
            )
            migrationRowDivider()
            migrationDetailRow(
                title: "Group",
                description: "Controls which repositories can use this runner.",
                value: runner.runnerGroup ?? "—"
            )
        }
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
