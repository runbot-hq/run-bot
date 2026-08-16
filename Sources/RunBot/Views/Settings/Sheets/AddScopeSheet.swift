// AddScopeSheet.swift
// RunBot
import GitHubClient
import RunBotCore
import SwiftUI

// ScopeType is defined in ScopeType.swift (F-45 / #1644).

// MARK: - AddScopeSheet

/// Modal sheet for adding a new remote runner scope (org or repo).
///
/// Mirrors `AddRunnerSheet` in structure: segmented type toggle at the top,
/// a searchable `RepoSelectorSheet` when authenticated (populated from the
/// GitHub API) with an explicit load-failure fallback, and Cancel / Add buttons.
///
/// On confirmation calls `ScopeStore.shared.add(_:)`. No `onRestartPolling`
/// callback is needed — `ScopeStore` mutation is observed by `RunnerStore`'s
/// `withObservationTracking` loop, which triggers restart automatically.
///
/// ## Why `.sheet` is on the root VStack, not the picker Button
/// `RepoSelectorSheet` is presented via `.sheet(isPresented: $showRepoSelector)`
/// and `.sheet(isPresented: $showOrgSelector)`.
/// Attaching those modifiers to the `Button` (nested inside a `VStack`) constrains
/// sheet presentation to the parent view bounds — i.e. the NSPopover panel size —
/// instead of escaping to the window level. Lifting them to the root `VStack` causes
/// AppKit to attach the sheet to `NSPopoverWindowFrame` directly, matching the
/// behaviour of `AddRunnerSheet` and preserving compatibility with the legacy
/// status-bar hierarchy that still reuses this sheet.
/// ❌ NEVER move `.sheet(isPresented: $showRepoSelector)` or `.sheet(isPresented: $showOrgSelector)`
/// back onto the individual Buttons.
///
/// ## Why no ScrollView in body
/// The content is a fixed set of controls (segmented picker, one field or button,
/// helper caption) that never needs to scroll. A `ScrollView` prevents SwiftUI from
/// computing a real `preferredContentSize` for the sheet window — it reports the
/// container height (the NSPopover panel size) instead of the content height.
/// Replacing it with a plain `VStack` lets the sheet size itself intrinsically.
/// ❌ NEVER wrap the content VStack in a ScrollView here.
struct AddScopeSheet: View {
    /// Controls whether the sheet is shown.
    @Binding var isPresented: Bool

    /// Shared authentication state injected from `ScopesView`.
    /// Used to check active-mode credential availability before attempting GitHub API fetches.
    let authentication: GitHubAuthentication

    /// Whether the scope is repo-level or org-level.
    /// Defaults to `.repo` to match `AddRunnerSheet` and the primary use case.
    @State private var scopeType: ScopeType = .repo
    /// The scope string chosen from the repository picker.
    /// Preserved independently across segment switches.
    @State private var selectedRepo: String = ""
    /// Organisation chosen from the org picker.
    /// Preserved independently across segment switches.
    @State private var selectedOrg: String = ""
    /// Manual text-field input; used only when the user explicitly taps "Enter manually".
    @State private var manualScope: String = ""
    /// Available organisation names fetched from GitHub.
    @State private var orgs: [String] = []
    /// Available repository names fetched from GitHub.
    @State private var repos: [String] = []
    /// `true` while org/repo options are being fetched.
    @State private var isFetching = false
    /// Non-nil when fetching or validation fails.
    @State private var errorMessage: String?
    /// `true` when the picker UI is shown instead of the load-failure view.
    @State private var usePicker = false
    /// `true` when the user has explicitly opted in to manual text entry after a failed fetch.
    @State private var allowsManualEntry = false
    /// `true` while the repository selector sheet is presented.
    @State private var showRepoSelector = false
    /// `true` while the organisation selector sheet is presented.
    @State private var showOrgSelector = false

    /// The picker selection for the currently active segment.
    private var selectedScopeForCurrentType: String {
        scopeType == .repo ? selectedRepo : selectedOrg
    }

    /// The scope string that will be saved.
    /// Uses the per-type picker selection when available, otherwise trimmed manual input.
    private var effectiveScope: String {
        if usePicker {
            let pick = selectedScopeForCurrentType
            if !pick.isEmpty { return pick }
        }
        return manualScope.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Guards the Add button: non-empty selection not already registered.
    ///
    /// `effectiveScope` is lowercased before the duplicate check because
    /// `ScopeStore.add` lowercases at the point of entry. Without normalisation
    /// a scope that differs only by case (e.g. `MyOrg/Repo` vs `myorg/repo`)
    /// would pass this guard, the sheet would close, but `ScopeStore.add`
    /// would silently no-op — leaving the user with no new scope and no error.
    private var canAdd: Bool {
        let normalised = effectiveScope.lowercased()
        return !normalised.isEmpty
            && !ScopeStore.shared.entries.contains { $0.scope == normalised }
    }

    /// Root layout: header, form fields, and footer action bar.
    ///
    /// No ScrollView — see type comment for why. Both `.sheet` modifiers
    /// are attached at the root so AppKit attaches selectors at window level.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──────────────────────────────────────────────────────────────────
            Text("Add remote scope")
                .font(.headline)
                .padding(.horizontal, RBSpacing.md)
                .padding(.top, RBSpacing.md)
                .padding(.bottom, RBSpacing.sm)

            Divider()

            VStack(alignment: .leading, spacing: RBSpacing.md) {

                // ── Type toggle ──────────────────────────────────────────────────
                Picker("", selection: $scopeType) {
                    ForEach(ScopeType.allCases) { scopeOption in
                        Text(scopeOption.rawValue).tag(scopeOption)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: scopeType) { _, _ in
                    // Each segment preserves its own selection independently.
                    // Only dismiss any open selector sheet and clear stale manual input.
                    manualScope = ""
                    showRepoSelector = false
                    showOrgSelector = false
                }

                // ── Scope field (repo or org) ─────────────────────────────────────
                if isFetching {
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading repositories…")
                            .font(.caption)
                            .foregroundColor(Color.rbTextSecondary)
                    }
                } else if usePicker {
                    if scopeType == .repo {
                        selectorButton(
                            label: "Repository",
                            selection: selectedRepo,
                            action: { showRepoSelector = true }
                        )
                    } else {
                        selectorButton(
                            label: "Organisation",
                            selection: selectedOrg,
                            action: { showOrgSelector = true }
                        )
                    }
                } else if allowsManualEntry {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scopeType == .repo ? "Repository" : "Organisation")
                            .font(.caption)
                            .foregroundColor(Color.rbTextSecondary)
                        TextField(
                            scopeType == .repo ? "e.g. myorg/myrepo" : "e.g. myorg",
                            text: $manualScope
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    }
                } else {
                    // Load failure — explicit error with Retry and manual fallback.
                    VStack(alignment: .leading, spacing: RBSpacing.sm) {
                        if let err = errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundColor(Color.rbDanger)
                        }
                        HStack(spacing: RBSpacing.sm) {
                            Button("Retry") {
                                fetchScopeOptions()
                            }
                            .controlSize(.small)
                            Button("Enter manually") {
                                allowsManualEntry = true
                            }
                            .controlSize(.small)
                        }
                    }
                }

                // ── Helper caption ───────────────────────────────────────────────────
                Text(scopeType == .org
                        ? "Monitors all runners in the organisation."
                        : "Monitors runners registered to this repository.")
                    .font(.caption)
                    .foregroundColor(Color.rbTextSecondary)
            }
            .padding(RBSpacing.md)

            Divider()

            // ── Button row ─────────────────────────────────────────────────────────────
            HStack {
                Spacer()

                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)

                Button(action: confirmAdd) {
                    Text("Add Scope")
                        .font(.system(size: 13, weight: .medium))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, RBSpacing.sm)
        }
        .frame(width: 420)
        // Both selector sheets are attached to the root VStack so AppKit presents them
        // at window level. Do NOT move these back onto the individual selector buttons.
        .sheet(isPresented: $showRepoSelector) {
            RepoSelectorSheet(
                items: repos,
                label: "Repository",
                onDismiss: { showRepoSelector = false },
                onSelect: { item in selectedRepo = item }
            )
        }
        .sheet(isPresented: $showOrgSelector) {
            RepoSelectorSheet(
                items: orgs,
                label: "Organisation",
                onDismiss: { showOrgSelector = false },
                onSelect: { item in selectedOrg = item }
            )
        }
        .onAppear(perform: fetchScopeOptions)
    }

    // MARK: - Sub-views

    /// Selector button matching the established `AddRunnerSheet+FormFields` design.
    ///
    /// Shows the current selection or the "— select —" placeholder.
    /// Uses the same label typography, insets, border, background, and chevron as
    /// `AddRunnerSheet.selectorButton`. Both sheets must stay visually identical.
    @ViewBuilder
    private func selectorButton(
        label: String,
        selection: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(Color.rbTextSecondary)
            Button(action: action) {
                HStack {
                    Text(selection.isEmpty ? "— select —" : selection)
                        .font(.system(size: 12))
                        .foregroundStyle(
                            selection.isEmpty
                                ? Color.rbTextSecondary
                                : Color.rbTextPrimary
                        )
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    /// Fetches orgs and repos via the shared `GitHubScopeOptionsLoader`.
    ///
    /// Uses the same loader as `AddRunnerSheet` so both sheets cannot diverge.
    /// Shows an explicit load-failure view (with Retry and Enter-manually actions)
    /// instead of silently falling back to a text field.
    @MainActor private func fetchScopeOptions() {
        guard authentication.isAuthenticated else {
            log("AddScopeSheet › active auth mode has no usable credential — showing load failure")
            usePicker = false
            errorMessage = "Could not load repositories and organisations."
            return
        }
        isFetching = true
        errorMessage = nil
        Task(priority: .userInitiated) {
            let options = await GitHubScopeOptionsLoader.load()
            await MainActor.run {
                repos = options.repositories
                orgs = options.organizations
                isFetching = false
                if options.isEmpty {
                    log("AddScopeSheet › fetch returned no orgs or repos — showing load failure")
                    usePicker = false
                    errorMessage = "Could not load repositories and organisations."
                    return
                }
                usePicker = true
                selectedRepo = selectedRepo.isEmpty ? repos.first ?? "" : selectedRepo
                selectedOrg = selectedOrg.isEmpty ? orgs.first ?? "" : selectedOrg
                log("AddScopeSheet › loaded orgs=\(orgs.count) repos=\(repos.count)")
            }
        }
    }

    /// Persists `effectiveScope` to `ScopeStore` and dismisses the sheet.
    /// Restart polling is driven automatically by `RunnerStore`'s
    /// `withObservationTracking` loop observing `ScopeStore` mutations.
    @MainActor private func confirmAdd() {
        let scope = effectiveScope
        guard !scope.isEmpty else { return }
        ScopeStore.shared.add(scope)
        log("AddScopeSheet › added scope: \(scope)")
        isPresented = false
    }
}
