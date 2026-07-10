// ScopeEditSheet.swift
// RunBot
import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - ScopeEditSheet

// Navigation level: SettingsView (scope row tap) → ScopeEditSheet (modal sheet)
//
// #499: Nav shell + wiring
// #513: Simplified — alias, polling, notifications sections removed.
//       Enable toggle moved from header into its own Monitoring section.
//       Monitoring row removed from Scope Info card.
// #539: Layout improvements -- section labels, card structure aligned with spec.
// #973: Remove Danger Zone and monitoring toggle — Settings is single source of truth.
// #992: Converted from nav drill-down to modal sheet with explicit Cancel / Save.
//       All edits are staged locally; ScopePreferencesStore is only written on Save.
// #1263: Removed ScrollView so sheet height is intrinsic (same fix as #1262).
// #1538: init now receives a pre-fetched ScopePreferences snapshot so seeds are
//        synchronous. confirmSave() is async — called via plain Task{} to keep
//        @MainActor isolation after the actor awaits (P9).
//        Header now shows alias (from snapshot) when set, raw scope otherwise.
// #1633: Route refreshDisplayNames() through injected scopeStore instead of .shared.
// #2009: Failure-hook fields removed; sheet is now read-only. confirmSave() only dismisses.
/// Modal sheet for editing settings of a single scope (org or repo).
/// Presented when the user taps a scope row in `ScopesView`.
///
/// ## Why no ScrollView
/// The content is a fixed set of sections (Info, Monitoring, optionally Failure Hook)
/// that never needs to scroll. A ScrollView prevents SwiftUI from computing a real
/// `preferredContentSize` for the sheet window — it reports the container height
/// (the NSPopover panel size) instead of the content height. Removing it lets the
/// root VStack size itself intrinsically, giving the sheet the correct independent height.
/// ❌ NEVER wrap the content VStack in a ScrollView here.
struct ScopeEditSheet: View {
    /// The scope entry being inspected. Treated as a snapshot; live state is
    /// re-read from `ScopeStore` via `liveEntry`.
    let scopeEntry: ScopeEntry
    /// Controls sheet dismissal. Set to `false` to close without saving;
    /// `confirmSave()` sets it to `false` after persisting changes.
    @Binding var isPresented: Bool

    /// Shared store providing the full list of scope entries.
    /// `@State` holds a reference to the singleton — safe even though
    /// `ScopeEditSheet` is recreated on each presentation, because `@State`
    /// stores the reference itself (not a copy), so both presentations point
    /// at the same `ScopeStore.shared` instance.
    @State private var scopeStore = ScopeStore.shared

    /// Display name shown in the sheet header: alias if set, raw scope string otherwise.
    /// Derived from the pre-fetched `ScopePreferences` snapshot in `init` so the
    /// header always reflects the user's alias without an extra actor hop. (#1538)
    private let headerDisplayName: String

    /// Creates the view, seeding `@State` draft values from a pre-fetched
    /// `ScopePreferences` snapshot.
    ///
    /// The caller (ScopesView) fetches preferences asynchronously before
    /// presenting the sheet and passes the result here, so this `init` remains
    /// synchronous and the seeds always reflect persisted preferences. (#1538)
    ///
    /// - Parameters:
    ///   - scopeEntry: The scope whose settings this view manages.
    ///   - preferences: Pre-fetched preferences snapshot for this scope.
    ///   - isPresented: Binding that controls sheet visibility.
    init(scopeEntry: ScopeEntry, preferences: ScopePreferences, isPresented: Binding<Bool>) {
        self.scopeEntry = scopeEntry
        self._isPresented = isPresented
        // Trim first, then use the trimmed value for both the empty check and the
        // assigned result. The previous code trimmed only to check emptiness but
        // returned the original $0, so leading/trailing whitespace could survive
        // into headerDisplayName if the stored alias arrived un-trimmed. (#1538)
        let alias = preferences.alias.flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.headerDisplayName = alias ?? scopeEntry.scope
    }

    /// The up-to-date entry from `ScopeStore`, or `nil` if the scope has been
    /// removed since this view was created.
    private var liveEntry: ScopeEntry? {
        scopeStore.entries.first(where: { $0.id == scopeEntry.id })
    }
    /// Whether monitoring is currently enabled for this scope.
    /// Falls back to the snapshot value if the live entry is unavailable.
    private var isEnabled: Bool { liveEntry?.isEnabled ?? scopeEntry.isEnabled }
    /// The raw scope string (e.g. `"owner/repo"` or `"owner"`).
    private var scope: String { scopeEntry.scope }
    /// `true` when the scope string contains a slash, indicating a repository
    /// scope rather than an organisation scope.
    private var isRepo: Bool { scope.contains("/") }
    /// The GitHub web URL for this scope, used to render the "Open on GitHub" link.
    private var gitHURL: URL? { URL(string: "https://github.com/\(scope)") }

    /// Root layout: header, divider, content sections, divider, and footer action bar.
    ///
    /// No ScrollView — see type comment for why. The sheet window sizes freely
    /// to the intrinsic height of this VStack via `preferredContentSize`.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                infoSection
                monitoringSection
            }
            .padding(.bottom, 16)
            Divider()
            buttonFooter
        }
        .frame(width: 440)
        .accessibilityIdentifier("scopeEditSheet")
    }
}

// MARK: - Header & Footer
/// Header and footer views for the scope edit sheet.
extension ScopeEditSheet {
    /// Sheet-style title header showing scope display name and type badge.
    var sheetHeader: some View {
        HStack(spacing: 6) {
            Text("Edit Scope")
                .font(.headline)
            Spacer()
            HStack(spacing: 6) {
                Text(isRepo ? "Repo" : "Org")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.rbSurfaceElevated))
                    .overlay(Capsule().strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
                // Shows alias when set, raw scope string otherwise.
                // `headerDisplayName` is derived from the pre-fetched ScopePreferences
                // snapshot in init — no extra actor hop needed. (#1538)
                Text(headerDisplayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, RBSpacing.md)
        .padding(.bottom, RBSpacing.sm)
    }

    /// Cancel / Save button row at the bottom of the sheet.
    var buttonFooter: some View {
        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.escape, modifiers: [])
            // Task{} is kept so the call site stays async-shaped: if confirmSave()
            // reacquires awaits when editable fields return, this button needs no
            // rewiring. The async boundary is currently a no-op placeholder. (P9)
            Button {
                Task { await confirmSave() }
            } label: {
                Text("Save")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, RBSpacing.sm)
    }
}

// MARK: - Sections
/// Content section views: scope info and monitoring status.
extension ScopeEditSheet {
    /// Card section displaying read-only scope metadata: raw scope string,
    /// type (repo vs org), and a link to open the scope on GitHub.
    var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Scope Info")
            infoCard {
                infoRow(label: "Scope", value: scope, copyable: true)
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Type", value: isRepo ? "Repository" : "Organisation")
                if let url = gitHURL {
                    Divider().padding(.leading, RBSpacing.md)
                    HStack(alignment: .top, spacing: 8) {
                        Text("GitHub")
                            .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading).fixedSize()
                        Button { NSWorkspace.shared.open(url) } label: {
                            HStack(spacing: 4) {
                                Text("Open on GitHub")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.rbAccent)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.rbAccent)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(url.absoluteString)
                        Spacer()
                    }
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                }
            }
        }
    }

    /// Card section displaying the current monitoring status for this scope as a read-only label.
    /// Toggle and remove controls live in Settings — see #973.
    var monitoringSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Monitoring")
            infoCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monitor this scope")
                            .font(.system(size: 12, weight: .medium))
                        Text(isEnabled
                                ? "RunBot actively polls this scope for runner status."
                                : "Polling is paused. No runner data will be fetched for this scope.")
                            .font(.caption2)
                            .foregroundColor(Color.rbTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(isEnabled ? "Active" : "Paused")
                        .font(.caption2)
                        .foregroundColor(isEnabled ? Color.rbSuccess : Color.rbTextTertiary)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 10)
            }
        }
    }
}

// MARK: - Actions
/// User-initiated actions: save and cancel.
extension ScopeEditSheet {
    /// Commits the sheet action.
    ///
    /// This sheet is currently read-only after failure-hook preference removal, so
    /// Save simply dismisses the sheet. The method remains async to preserve the
    /// existing `Task { await confirmSave() }` call site and keep future editable
    /// fields easy to reintroduce without rewiring the button action.
    @MainActor func confirmSave() async {
        isPresented = false
    }
}

// MARK: - Sub-view helpers
/// Reusable sub-view factory methods shared across section extensions.
extension ScopeEditSheet {
    /// Renders a styled section-header label.
    /// - Parameter title: The display text for the section heading.
    func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 4)
    }

    /// Wraps `content` in the standard rounded-card background used across all
    /// settings sections.
    /// - Parameter content: The view builder producing the card's contents.
    func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .glassCard(cornerRadius: RBRadius.small)
        .padding(.horizontal, RBSpacing.md)
        .padding(.bottom, 8)
    }

    /// Renders a label–value row inside an info card.
    /// - Parameters:
    ///   - label: The left-aligned field name (fixed 100 pt width).
    ///   - value: The monospaced value string displayed to the right.
    ///   - copyable: When `true`, a copy-to-clipboard button is appended.
    func infoRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading).fixedSize()
            Text(value)
                .font(.system(size: 12, design: .monospaced)).foregroundColor(Color.rbTextPrimary)
                .lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(Color.rbTextTertiary)
                }
                .buttonStyle(.plain).help("Copy to clipboard")
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
    }
}
