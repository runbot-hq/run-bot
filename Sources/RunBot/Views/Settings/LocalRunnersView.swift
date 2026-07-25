// LocalRunnersView.swift
// RunBot
import MenuBarKit
import RunBotCore
import SwiftUI

// MARK: - LocalRunnersView

/// Full runner-management screen, reached from the "Manage local runners" row in Settings.
///
/// Owns all runner-specific state and lifecycle actions that previously lived in `SettingsView`.
/// Presented by `SettingsView` via a `showLocalRunners` flag using the same back-callback
/// pattern established by the rest of the panel navigation model.
@MainActor
struct LocalRunnersView: View {

    // MARK: - Inputs

    /// Callback invoked when the user taps the back button.
    let onBack: () -> Void
    /// Combined OAuth + CLI auth state forwarded from `SettingsView`; required by `RemovalAlertModifier`.
    let isAuthenticated: Bool

    // MARK: - Local runner store (for mutations only — state is read from RunnerState environment)

    /// The local runner actor. Used only for mutations (refresh, optimistic updates).
    /// Observed state (`localRunners`, `isLocalScanning`) is read from the `RunnerState`
    /// environment object injected by `AppDelegate.wrapEnv`.
    /// Injected by the caller; defaults to `LocalRunnerStore.shared` at the `SettingsView` boundary.
    var localRunnerStore: LocalRunnerStore = .shared

    /// Runner lifecycle service. Injected from `SettingsView` (which receives it from `AppDelegate`).
    /// Typed to protocol so tests can supply a stub without spawning real `svc.sh` processes (P7).
    /// No default — callers must supply the `AppDelegate`-owned instance explicitly.
    var lifecycleService: any RunnerLifecycleServiceProtocol

    // MARK: - Environment

    /// Core runner state — localRunners and isLocalScanning are read from here.
    @Environment(AppState.self) private var appState
    /// Gate that tracks whether any overlay is live; managed by `mbkSheet` automatically.
    /// Arms the outside-click monitor for the full sheet lifetime, including the brief
    /// window between editingRunner = nil and the sheet NSWindow detaching — making
    /// the old suppressHidePanel() call redundant.
    @Environment(MBKOverlayGate.self) private var overlayGate: MBKOverlayGate

    // MARK: - Local UI state

    /// `true` once the initial local runner scan has completed.
    @State private var hasLoadedOnce = false
    /// The runner awaiting user confirmation before removal.
    @State private var runnerPendingRemoval: RunnerModel?
    /// Controls presentation of `AddRunnerSheet`.
    @State private var showAddRunnerSheet = false
    /// The runner currently being edited in `RunnerDetailSheet`. `nil` = sheet dismissed.
    @State private var editingRunner: RunnerModel?
    /// `true` while a save is in-flight.
    @State private var isCommitting = false
    /// Non-nil when the last commit attempt produced errors; forwarded into `RunnerDetailSheet`.
    @State private var commitError: String?
    /// Non-nil when the last removal attempt failed; shown as an inline error label.
    @State private var removeErrorMessage: String?

    // MARK: - Computed properties

    /// Alert title incorporating the pending runner name.
    private var removalAlertTitle: String {
        let name = runnerPendingRemoval?.runnerName ?? "this runner"
        return "Remove runner \"\(name)\"?"
    }

    // MARK: - Body

    /// Root layout: fixed header bar above a scrollable runner list.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                contentStack
                    .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
        .onAppear { Task { await localRunnerStore.refresh() } }
        .onChange(of: appState.runnerState.isLocalScanning) { _, newVal in if !newVal { hasLoadedOnce = true } }
        .mbkSheet(isPresented: $showAddRunnerSheet) { addRunnerSheet() }
        .modifier(removalAlertModifier)
        .mbkSheet(item: $editingRunner) { runner in
            runnerEditingSheet(runner: runner)
        }
    }

    // MARK: - Header

    /// Top bar with back button and "Manage local runners" title.
    private var headerBar: some View {
        HStack {
            Button(action: onBack, label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("Manage local runners").font(.headline)
                }
                .foregroundColor(.primary)
            })
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: - Content

    /// Vertical stack of the runner list and related controls.
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            descriptionLabel
            errorLabel
            runnerList
        }
    }

    /// Section header row with add and refresh buttons.
    private var sectionHeader: some View {
        HStack {
            Text("Active local runners")
                .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            Spacer()
            Button(action: { showAddRunnerSheet = true }, label: {
                Image(systemName: "plus").font(.caption).foregroundColor(Color.rbTextSecondary)
            })
            .buttonStyle(.plain)
            .help("Add a new runner")
            .accessibilityIdentifier("addRunnerButton")
            .padding(.trailing, 4)
            if appState.runnerState.isLocalScanning {
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
            } else {
                Button(action: { removeErrorMessage = nil; Task { await localRunnerStore.refresh() } }, label: {
                    Image(systemName: "arrow.clockwise").font(.caption).foregroundColor(Color.rbTextSecondary)
                })
                .buttonStyle(.plain).help("Refresh local runner list")
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
    }

    /// Subtitle describing what local runners are.
    private var descriptionLabel: some View {
        Text("Self-hosted runners installed on this machine, discovered via LaunchAgent plists.")
            .font(.caption).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
    }

    /// Inline error label shown when the last removal failed.
    @ViewBuilder
    private var errorLabel: some View {
        if let errMsg = removeErrorMessage {
            Text(errMsg).font(.caption).foregroundColor(Color.rbDanger)
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 4)
                .background(Color.rbDanger.opacity(0.07))
        }
    }

    /// Empty-state placeholder or populated list of runner rows.
    @ViewBuilder
    private var runnerList: some View {
        if appState.runnerState.localRunners.isEmpty && !appState.runnerState.isLocalScanning && hasLoadedOnce {
            Text("No local runners found").font(.caption).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 4)
        } else {
            ForEach(appState.runnerState.localRunners) { runner in localRunnerRow(runner) }
        }
    }

    // MARK: - Runner rows

    /// Full row view for a single local runner, including the detail sheet trigger.
    private func localRunnerRow(_ runner: RunnerModel) -> some View {
        Button {
            commitError = nil
            editingRunner = runner
        } label: {
            localRunnerRowContent(runner)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 5)
        .glassCard(cornerRadius: RBRadius.small)
        .padding(.horizontal, RBSpacing.xs)
    }

    /// Inner content (status dot, name, start/stop toggle, remove button) for a local runner row.
    private func localRunnerRowContent(_ runner: RunnerModel) -> some View {
        let hasWarning = runner.lifecycleWarning != nil
        let displayStatus = runner.displayStatus
        return HStack(spacing: 6) {
            Circle().fill(runner.statusColor.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(runner.runnerName).font(.system(size: 13)).lineLimit(1)
                if let url = runner.gitHubUrl {
                    Text(url.absoluteString).font(.caption2).foregroundColor(Color.rbTextSecondary).lineLimit(1)
                }
            }
            Spacer()
            Text(displayStatus)
                .font(.caption)
                .foregroundColor(hasWarning ? Color.rbWarning : Color.rbTextSecondary)
                .lineLimit(1)
                .fixedSize()
            Toggle("", isOn: Binding(
                get: { runner.isRunning },
                set: { isOn in
                    if isOn { performResume(runner: runner) } else { performStop(runner: runner) }
                }
            ))
            .toggleStyle(.switch)
            .tint(Color.rbSuccess)
            .labelsHidden()
            .help(runner.isRunning ? "Stop runner service" : "Start runner service")
            .scaleEffect(0.8, anchor: .trailing)
            .buttonStyle(.borderless)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(Color.rbTextTertiary)
            Button(action: { runnerPendingRemoval = runner },
                   label: { Image(systemName: "minus.circle").font(.caption2).foregroundColor(Color.rbDanger) })
                .buttonStyle(.plain).help("Remove runner")
        }
    }

    // MARK: - Lifecycle actions

    /// Optimistically marks the runner as running then delegates to `lifecycleService`.
    @MainActor private func performResume(runner: RunnerModel) {
        log("LocalRunnersView > performResume called runner=\(runner.runnerName)")
        Task(priority: .userInitiated) {
            await localRunnerStore.optimisticallySetRunning(runner.runnerName, isRunning: true)
            let result = await lifecycleService.start(runner: runner)
            switch result {
            case .success: break
            case .corruptInstall:
                await localRunnerStore.optimisticallySetRunning(runner.runnerName, isRunning: false)
                await localRunnerStore.setLifecycleWarning(runner.runnerName, warning: "\u{26A0} corrupt install")
            case .failed(let msg):
                await localRunnerStore.optimisticallySetRunning(runner.runnerName, isRunning: false)
                let short = msg.components(separatedBy: "\n")
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? msg
                await localRunnerStore.setLifecycleWarning(runner.runnerName, warning: "\u{26A0} \(short)")
            }
            await localRunnerStore.refresh()
        }
    }

    /// Optimistically marks the runner as stopped then delegates to `lifecycleService`.
    @MainActor private func performStop(runner: RunnerModel) {
        log("LocalRunnersView > performStop called runner=\(runner.runnerName)")
        Task(priority: .userInitiated) {
            await localRunnerStore.optimisticallySetRunning(runner.runnerName, isRunning: false)
            let result = await lifecycleService.stop(runner: runner)
            switch result {
            case .success: break
            case .corruptInstall:
                await localRunnerStore.setLifecycleWarning(runner.runnerName, warning: "\u{26A0} corrupt install")
            case .failed(let msg):
                await localRunnerStore.optimisticallySetRunning(runner.runnerName, isRunning: true)
                let short = msg.components(separatedBy: "\n")
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? msg
                await localRunnerStore.setLifecycleWarning(runner.runnerName, warning: "\u{26A0} \(short)")
            }
            await localRunnerStore.refresh()
        }
    }

    /// Optimistically removes the runner then delegates to `lifecycleService`. Rolls back on failure.
    @MainActor private func performRemoval() {
        guard let runner = runnerPendingRemoval else { return }
        runnerPendingRemoval = nil
        removeErrorMessage = nil
        Task(priority: .userInitiated) {
            await localRunnerStore.optimisticallyRemove(runner.runnerName)
            let result = await lifecycleService.remove(runner: runner)
            switch result {
            case .success:
                break
            case .corruptInstall:
                await localRunnerStore.optimisticallyRestore(runner)
                removeErrorMessage = "Runner \"\(runner.runnerName)\" has a corrupt install. Check logs."
            case .failed(let msg):
                await localRunnerStore.optimisticallyRestore(runner)
                let short = msg.components(separatedBy: "\n")
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? msg
                removeErrorMessage = "Failed to remove \"\(runner.runnerName)\": \(short)"
            }
            await localRunnerStore.refresh()
        }
    }

    // MARK: - Helpers

    /// Returns the configured `AddRunnerSheet` for use as a `.mbkSheet` content closure.
    private func addRunnerSheet() -> some View {
        AddRunnerSheet(
            isPresented: $showAddRunnerSheet,
            onComplete: { Task { await localRunnerStore.refresh() } },
            localRunnerStore: localRunnerStore
        )
    }

    /// Pre-configured `RemovalAlertModifier` wired to `runnerPendingRemoval`.
    private var removalAlertModifier: RemovalAlertModifier {
        RemovalAlertModifier(
            title: removalAlertTitle,
            isPresented: Binding(
                get: { runnerPendingRemoval != nil },
                set: { if !$0 { runnerPendingRemoval = nil } }
            ),
            isAuthenticated: isAuthenticated,
            onCancel: { runnerPendingRemoval = nil },
            onConfirm: performRemoval
        )
    }

    /// Builds the `RunnerDetailSheet` with commit/cancel wiring.
    ///
    /// `overlayGate.hasActiveOverlay` is kept armed by `.mbkSheet(item:)` for
    /// the full sheet lifetime, including the brief window between `editingRunner = nil`
    /// and the sheet NSWindow detaching. The old `suppressHidePanel()` call is therefore
    /// not needed here — the gate covers the dismiss window structurally.
    @ViewBuilder
    private func runnerEditingSheet(runner: RunnerModel) -> some View {
        RunnerDetailSheet(
            runner: runner,
            commitError: commitError,
            onCommit: { draft in
                guard !isCommitting else { return }
                isCommitting = true
                commitError = nil
                Task(priority: .userInitiated) {
                    var original = RunnerEditDraft(runner: runner)
                    if let installPath = runner.installPath {
                        await original.load(
                            installPath: installPath,
                            configStore: RunnerConfigStore.shared,
                            proxyStore: RunnerProxyStore.shared
                        )
                    }
                    let useCase = SaveRunnerEditsUseCase(
                        configStore: RunnerConfigStore.shared,
                        proxyStore: RunnerProxyStore.shared,
                        labelsService: DefaultRunnerLabelsService()
                    )
                    let result = await useCase.execute(runner: runner, draft: draft, original: original)
                    await MainActor.run {
                        isCommitting = false
                        switch result {
                        case .success:
                            Task { await localRunnerStore.refresh() }
                            editingRunner = nil
                        case .failure(let msgs):
                            commitError = msgs.joined(separator: "\n")
                        }
                    }
                }
            },
            onCancel: {
                commitError = nil
                editingRunner = nil
            }
        )
    }
}
