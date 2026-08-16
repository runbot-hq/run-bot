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
/// GitHub API) with a plain `TextField` fallback, and Cancel / Add buttons.
///
/// On confirmation calls `ScopeStore.shared.add(_:)`. No `onRestartPolling`
/// callback is needed — `ScopeStore` mutation is observed by `RunnerStore`'s
/// `withObservationTracking` loop, which triggers restart automatically.
///
/// ## Why `.sheet` is on the root VStack, not the picker Button
/// `RepoSelectorSheet` is presented via `.sheet(isPresented: $showScopeSelector)`.
/// Attaching that modifier to the `Button` (nested inside a `ScrollView`) constrains
/// sheet presentation to the parent view bounds — i.e. the NSPopover panel size —
/// instead of escaping to the window level. Lifting it to the root `VStack` causes
/// AppKit to attach the sheet to `NSPopoverWindowFrame` directly, matching the
/// behaviour of `AddRunnerSheet` and `AddScopeSheet`'s own outer presentation.
/// ❌ NEVER move `.sheet(isPresented: $showScopeSelector)` back onto the Button.
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

    /// Whether the scope is org-level or repo-level.
    @State private var scopeType: ScopeType = .org
    /// The scope string chosen from the picker.
    @State private var selectedRepo: String = ""
    /// Organisation chosen from the org picker (kept independently across segment switches).
    @State private var selectedOrg: String = ""
    /// Manual text-field input; used when picker data is unavailable.
    @State private var manualScope: String = ""
    /// Available organisation names fetched from GitHub.
    @State private var orgs: [String] = []
    /// Available repository names fetched from GitHub.
    @State private var repos: [String] = []
    /// `true` while org/repo options are being fetched.
    @State private var isFetching = false
    /// Non-nil when fetching or validation fails.
    @State private var errorMessage: String?
    /// `true` when the picker UI is shown instead of the text field.
    @State private var usePicker = false
    /// `true` while the repository selector sheet is presented.
    @State private var showRepoSelector = false
    /// `true` while the organisation selector sheet is presented.
    @State private var showOrgSelector = false

    /// The picker selection for the currently active segment.
    private var selectedScopeForCurrentType: String {
        scopeType == .org ? selectedOrg : selectedRepo
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
    private var canAdd: Bool {
        !effectiveScope.isEmpty
            && !ScopeStore.shared.entries.contains { $0.scope == effectiveScope }
    }

    /// Root layout: header, form fields, and footer action bar.
    ///
    /// No ScrollView — see type comment for why. `.sheet(isPresented: $showScopeSelector)`
    /// is attached at the root so AppKit attaches `RepoSelectorSheet` at window level.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ─────────────────────────────────────────────────────
            Text("Add remote scope")
                .font(.headline)
                .padding(.horizontal, RBSpacing.md)
                .padding(.top, RBSpacing.md)
                .padding(.bottom, RBSpacing.sm)

            Divider()

            VStack(alignment: .leading, spacing: RBSpacing.md) {

                // ── Type toggle ──────────────────────────────────────────
                Picker("", selection: $scopeType) {
                    ForEach(ScopeType.allCases) { scopeOption in
                        Text(scopeOption.rawValue).tag(scopeOption)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: scopeType) { _, _ in
                    // Reset picker selection to the first item in the new segment (or "" if not
                    // loaded yet). Also clear manualScope so the text field doesn't show stale
                    // input from the previous segment when falling back to manual mode.
                    manualScope = ""
                    showRepoSelector = false
                    showOrgSelector = false
                }

                // -- Repository picker
                if scopeType == .repo {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Repository").font(.caption).foregroundColor(Color.rbTextSecondary)
                        if isFetching {
                            ProgressView().scaleEffect(0.7).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        } else if usePicker && !repos.isEmpty {
                            Button(action: { showRepoSelector = true }) {
                                HStack {
                                    Text(selectedRepo.isEmpty ? "select repo" : selectedRepo)
                                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                            .sheet(isPresented: $showRepoSelector) {
                                RepoSelectorSheet(items: repos, label: "Repository", onDismiss: { showRepoSelector = false }, onSelect: { item in selectedRepo = item })
                            }
                        } else {
                            TextField("e.g. myorg/myrepo", text: $manualScope).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        }
                        if let err = errorMessage { Text(err).font(.caption).foregroundColor(Color.rbDanger) }
                    }
                }

                // -- Organisation picker
                if scopeType == .org {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Organisation").font(.caption).foregroundColor(Color.rbTextSecondary)
                        if isFetching {
                            ProgressView().scaleEffect(0.7).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        } else if usePicker && !orgs.isEmpty {
                            Button(action: { showOrgSelector = true }) {
                                HStack {
                                    Text(selectedOrg.isEmpty ? "select org" : selectedOrg)
                                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                            .sheet(isPresented: $showOrgSelector) {
                                RepoSelectorSheet(items: orgs, label: "Organisation", onDismiss: { showOrgSelector = false }, onSelect: { item in selectedOrg = item })
                            }
                        } else {
                            TextField("e.g. myorg", text: $manualScope).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        }
                        if let err = errorMessage { Text(err).font(.caption).foregroundColor(Color.rbDanger) }
                    }
                }
                // ── Helper caption ───────────────────────────────────────
                Text(scopeType == .org
                        ? "Monitors all runners in the organisation."
                        : "Monitors runners registered to this repository.")
                    .font(.caption)
                    .foregroundColor(Color.rbTextSecondary)
            }
            .padding(RBSpacing.md)

            Divider()

            // ── Button row ─────────────────────────────────────────────────
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
        .onAppear(perform: fetchScopeOptions)
    }

    // MARK: - Actions

    /// Fetches orgs and repos from GitHub on a background thread.
    /// Falls back to manual text entry when no token is present or the fetch returns empty results.
    /// Pattern matches `LocalRunnerStore.refresh()`: background work is off-actor via
    /// `Task.detached`, then the `Task` continuation returns to `@MainActor` automatically.
    @MainActor private func fetchScopeOptions() {
        guard authentication.isAuthenticated else {
            log("AddScopeSheet \u{203a} active auth mode has no usable credential \u{2014} falling back to text field")
            usePicker = false
            return
        }
        isFetching = true
        errorMessage = nil
        Task(priority: .userInitiated) {
            async let fetchedOrgs = fetchUserOrgs()
            async let fetchedRepos = fetchUserRepos()
            let (resolvedOrgs, resolvedRepos) = await (fetchedOrgs, fetchedRepos)
            isFetching = false
            if resolvedOrgs.isEmpty && resolvedRepos.isEmpty {
                log("AddScopeSheet \u{203a} fetch returned no orgs or repos \u{2014} using text field")
                usePicker = false
                errorMessage = "Could not load orgs/repos. Enter manually."
            } else {
                orgs = resolvedOrgs
                repos = resolvedRepos
                usePicker = true
                selectedRepo = repos.first ?? ""
                selectedOrg = orgs.first ?? ""
                log("AddScopeSheet \u{203a} loaded orgs=\(orgs.count) repos=\(repos.count)")
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
        log("AddScopeSheet \u{203a} added scope: \(scope)")
        isPresented = false
    }
}
