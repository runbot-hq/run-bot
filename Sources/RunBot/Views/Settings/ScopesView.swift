// ScopesView.swift
// RunBot
import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - ScopesView

/// Full scope-management screen, reached from the "Manage scopes" row in Settings.
///
/// Owns all scope-specific state and sheet presentation that previously lived in `SettingsView`.
/// Presented by `SettingsView` via a `showScopes` flag using the same back-callback
/// pattern established by the rest of the panel navigation model.
///
/// No `onRestartPolling` callback is needed — all `ScopeStore` mutations
/// (add, remove, enable/disable) are observed by `RunnerStore`'s
/// `withObservationTracking` loop, which restarts the poll task automatically.
@MainActor
struct ScopesView: View {

    // MARK: - Inputs

    /// Callback invoked when the user taps the back button.
    let onBack: () -> Void

    /// OAuth service injected from `SettingsView` → `AppDelegate`.
    /// Forwarded into `AddScopeSheet` to check token availability.
    var oauthService: any OAuthServiceProtocol

    // MARK: - Observed stores

    /// Registered remote runner scopes (org / repo URLs).
    @State private var scopeStore = ScopeStore.shared

    // MARK: - Local UI state

    /// Controls presentation of `AddScopeSheet`.
    @State private var showAddScopeSheet = false
    /// Non-nil while `ScopeEditSheet` is being presented for a scope entry.
    @State private var selectedScopeEntry: ScopeEntry?
    /// Pre-fetched preferences snapshot for `selectedScopeEntry`.
    /// Fetched asynchronously on row tap before the sheet is presented,
    /// so `ScopeEditSheet.init` remains synchronous. (#1538)
    /// Cleared automatically whenever `selectedScopeEntry` becomes nil via
    /// the `onChange` modifier below, keeping the two pieces of state in sync
    /// regardless of how the sheet is dismissed. (#1538)
    @State private var selectedScopePreferences: ScopePreferences?

    // MARK: - Body

    /// Root layout: fixed header bar above a scrollable scope list.
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
        .sheet(isPresented: $showAddScopeSheet) {
            AddScopeSheet(isPresented: $showAddScopeSheet, oauthService: oauthService)
        }
        // Sheet is presented only once both entry and preferences snapshot are ready.
        // The Binding maps nil/non-nil of selectedScopeEntry to Bool.
        // The else branch is defensive — both state writes happen in the same
        // @MainActor turn after the await, so it should never be visible. (#1538)
        .sheet(item: $selectedScopeEntry) { entry in
            if let prefs = selectedScopePreferences {
                // #992: ScopeEditSheet replaces the old nav drill-down.
                // #1538: preferences snapshot passed in so init stays synchronous.
                ScopeEditSheet(
                    scopeEntry: entry,
                    preferences: prefs,
                    isPresented: Binding(
                        get: { selectedScopeEntry != nil },
                        set: { if !$0 { selectedScopeEntry = nil; selectedScopePreferences = nil } }
                    )
                )
            } else {
                // Preferences not yet fetched — renders an empty sheet rather than
                // a blank/crashed view in the theoretical race described above.
                EmptyView()
            }
        }
        // Self-enforcing invariant: whenever selectedScopeEntry is cleared from *any*
        // code path (sheet dismiss via binding, external nil-out, future refactors),
        // selectedScopePreferences is cleared with it. Prevents a stale snapshot from
        // a previously selected scope persisting in memory. (#1538)
        .onChange(of: selectedScopeEntry) { _, newEntry in
            if newEntry == nil { selectedScopePreferences = nil }
        }
    }

    // MARK: - Header

    /// Top bar with back button and "Manage scopes" title.
    private var headerBar: some View {
        HStack {
            Button(action: onBack, label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("Manage scopes").font(.headline)
                }
                .foregroundColor(.primary)
            })
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: - Content

    /// Vertical stack of the section header and scope list.
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            descriptionLabel
            scopeList
        }
    }

    /// Section header row with add button.
    private var sectionHeader: some View {
        HStack {
            Text("Remote runner scopes")
                .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            Spacer()
            Button {
                showAddScopeSheet = true
            } label: {
                Image(systemName: "plus").font(.caption).foregroundColor(Color.rbTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Add a remote scope")
            .accessibilityIdentifier("addScopeButton")
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 2)
    }

    /// Subtitle describing what remote scopes are.
    private var descriptionLabel: some View {
        Text("GitHub repos or orgs whose runners are fetched via the API.")
            .font(.caption).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
    }

    /// Empty-state placeholder or populated list of scope rows.
    @ViewBuilder
    private var scopeList: some View {
        if scopeStore.entries.isEmpty {
            Text("No remote scopes added")
                .font(.caption).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 4)
        } else {
            ForEach(scopeStore.entries) { entry in scopeRow(entry) }
        }
    }

    // MARK: - Scope rows

    /// Row view for a single remote scope entry.
    ///
    /// `displayName` and `alias` are read from `ScopeStore`'s cached observable state
    /// (written back by `ScopePreferencesStore` on save), so this stays synchronous.
    /// Full actor reads happen in the tap handler below.
    private func scopeRow(_ entry: ScopeEntry) -> some View {
        let isRepo = entry.scope.contains("/")
        let displayName = entry.displayName ?? entry.scope
        let hasAlias = entry.displayName != nil
        return Button {
            // Guard against double-taps: if a sheet is already being prepared or presented,
            // ignore the second tap entirely. Without this, two simultaneous Tasks could
            // complete out-of-order and pair selectedScopePreferences from scope A with
            // selectedScopeEntry for scope B. (#1538)
            guard selectedScopeEntry == nil else { return }
            // Fetch preferences from the actor before presenting the sheet.
            // Plain Task{} — inherits @MainActor, sheet presentation happens
            // on main actor after the await. (P9)
            Task {
                let prefs = await ScopePreferencesStore.shared.preferences(for: entry.scope)
                selectedScopePreferences = prefs
                selectedScopeEntry = entry
            }
        } label: {
            HStack(spacing: 8) {
                Text(isRepo ? "Repo" : "Org")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.rbSurfaceElevated))
                    .overlay(Capsule().strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if hasAlias {
                        Text(entry.scope)
                            .font(.caption2)
                            .foregroundColor(Color.rbTextTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Text(entry.isEnabled ? "Active" : "Paused")
                    .font(.caption2)
                    .foregroundColor(entry.isEnabled ? Color.rbSuccess : Color.rbTextTertiary)
                Toggle("", isOn: Binding(
                    get: { entry.isEnabled },
                    // ScopeStore enable/disable is observed by RunnerStore.startObservingScopes
                    // via withObservationTracking — no explicit restart needed here.
                    set: { scopeStore.setEnabled(entry.id, $0) }
                ))
                .toggleStyle(.switch)
                .tint(Color.rbSuccess)
                .labelsHidden()
                .help(entry.isEnabled ? "Pause monitoring" : "Resume monitoring")
                .scaleEffect(0.8, anchor: .trailing)
                .buttonStyle(.borderless)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextTertiary)
                Button {
                    // cleanUp MUST complete before remove so that the poll loop
                    // restart triggered by ScopeStore.remove cannot race a
                    // not-yet-cleaned preferences blob on the next tick. (#1538)
                    Task {
                        await ScopePreferencesStore.shared.cleanUp(scope: entry.scope)
                        scopeStore.remove(id: entry.id)
                        // ScopeStore.remove mutates activeScopes, firing
                        // withObservationTracking in startObservingScopes and
                        // restarting the poll loop automatically.
                    }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.caption2)
                        .foregroundColor(Color.rbDanger)
                }
                .buttonStyle(.borderless)
                .help("Remove scope")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 5)
        .glassCard(cornerRadius: RBRadius.small)
        .padding(.horizontal, RBSpacing.xs)
        .opacity(entry.isEnabled ? 1.0 : 0.5)
    }
}
