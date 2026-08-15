// RunnerDetailContentView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - RunnerDetailContentView

/// Reusable read-only body extracted from `RunnerDetailSheet`.
///
/// Used directly in the migration two-pane detail pane so the detail pane
/// does not present a modal sheet inside itself.
/// `RunnerDetailSheet` keeps wrapping this view for the legacy panel flow.
struct RunnerDetailContentView: View {

    // MARK: - Inputs

    let runner: RunnerModel

    // MARK: - Display fields (loaded from .runner JSON)

    @State private var displayOsArch: String = ""
    @State private var displayVersion: String = ""

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Runner Info")
                infoCard {
                    if let url = runner.gitHubUrl {
                        infoRow(label: "GitHub URL", value: url.absoluteString, copyable: true)
                        Divider().padding(.leading, RBSpacing.md)
                    }
                    infoRow(label: "Work folder", value: runner.workFolder ?? "_work")
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Ephemeral", value: runner.isEphemeral ? "Yes" : "No")
                    if !displayOsArch.isEmpty {
                        Divider().padding(.leading, RBSpacing.md)
                        infoRow(label: "OS / Arch", value: displayOsArch)
                    }
                    if !displayVersion.isEmpty {
                        Divider().padding(.leading, RBSpacing.md)
                        infoRow(label: "Version", value: displayVersion)
                    }
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Status", value: runner.displayStatus)
                }

                sectionHeader("Configuration")
                infoCard {
                    if runner.labels.isEmpty {
                        infoRow(label: "Labels", value: "—")
                    } else {
                        infoRow(label: "Labels", value: runner.labels.joined(separator: ", "))
                    }
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Group", value: runner.runnerGroup ?? "—")
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .task { await loadDisplayFields() }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader)
            .foregroundStyle(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .glassCard(cornerRadius: RBRadius.small)
            .padding(.horizontal, RBSpacing.md)
            .padding(.bottom, 8)
    }

    private func infoRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading)
                .fixedSize()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.rbTextPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.rbTextTertiary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 7)
    }

    // MARK: - Load display fields

    @MainActor
    private func loadDisplayFields() async {
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
        if let v = config.agentVersion, !v.isEmpty { displayVersion = v }
    }
}
