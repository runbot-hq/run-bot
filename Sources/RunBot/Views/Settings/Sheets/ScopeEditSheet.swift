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
// #544: Failure Hook section added between Monitoring and Danger Zone.
// #546: Local Path row — inline editing, NSOpenPanel folder picker, tilde pre-fill.
// #559: Failure Hook section hidden for org scopes — only shown for repo scopes.
// #560: Branch selector row added to Failure Hook section.
// #973: Remove Danger Zone and monitoring toggle — Settings is single source of truth.
// #992: Converted from nav drill-down to modal sheet with explicit Cancel / Save.
//       All edits are staged locally; ScopePreferencesStore is only written on Save.
//       NSOpenPanel runs without closing the panel — the NSPanel is non-activating
//       so it does not obscure the picker.
// #1263: Removed ScrollView so sheet height is intrinsic (same fix as #1262).
// #1538: init now receives a pre-fetched ScopePreferences snapshot so seeds are
//        synchronous. confirmSave() is async — called via plain Task{} to keep
//        @MainActor isolation after the actor awaits (P9).
//        Header now shows alias (from snapshot) when set, raw scope otherwise.
//        confirmSave() uses modifyPreferences(for:with:) for an atomic RMW (P10).
// #1633: Route refreshDisplayNames() through injected scopeStore instead of .shared.
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
    /// Controls visibility of the failure-hook configuration sheet.
    @State private var showHookSheet = false
    /// Controls visibility of the branch-filter picker sheet.
    @State private var showBranchSheet = false
    /// Draft: whether the failure hook is enabled. Written to store only on Save.
    @State private var hookEnabled: Bool
    /// Draft: selected branch filter. Written to store only on Save.
    @State private var hookBranch: String?
    /// Draft: failure-hook command. Written to store only on Save.
    @State private var hookCommand: String
    /// Draft: local repo path. Written to store only on Save.
    @State private var localRepoPath: String
    /// Tracks whether the inline path text field is in edit mode.
    @State private var isEditingPath = false
    /// The NSWindow hosting this sheet, captured early via WindowGrabber so
    /// it is reliably available when openFolderPicker() is called. (#1195)
    @State private var hostWindow: NSWindow?
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
        _hookEnabled = State(initialValue: preferences.failureHookEnabled)
        _hookBranch = State(initialValue: preferences.failureHookBranch)
        // Seed with the persisted value or empty string — never the default command.
        // FailureHookRunner falls back to its own default at runtime when the stored
        // value is nil, so seeding with the default here would silently persist it
        // on the first Save even when the user never opened FailureHookCommandSheet.
        _hookCommand = State(initialValue: preferences.failureHookCommand ?? "")
        _localRepoPath = State(initialValue: preferences.localRepoPath ?? "")
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
                if isRepo { failureHookSection }
            }
            .padding(.bottom, 16)
            Divider()
            buttonFooter
        }
        .frame(width: 440)
        .accessibilityIdentifier("scopeEditSheet")
        // Capture the hosting NSWindow as early as possible so beginSheetModal
        // has a reliable reference when openFolderPicker() is called. (#1195)
        .background(WindowGrabber { w in
            if hostWindow == nil, let w { hostWindow = w }
        })
        .sheet(isPresented: $showHookSheet) {
            FailureHookCommandSheet(scope: scope, localRepoPath: localRepoPath, commandText: $hookCommand) { showHookSheet = false }
        }
        .sheet(isPresented: $showBranchSheet) {
            BranchSelectorSheet(
                scope: scope,
                onDismiss: { showBranchSheet = false },
                onSelect: { chosen in
                    // Stage locally only — not persisted until Save.
                    hookBranch = chosen
                    showBranchSheet = false
                }
            )
        }
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
            // confirmSave() is async (actor writes). Plain Task{} inherits @MainActor
            // from the SwiftUI context so `isPresented = false` after the awaits
            // still runs on @MainActor — no isolation gap. (P9)
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
/// Content section views: scope info, monitoring status, and failure-hook configuration.
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

    /// Card section for configuring the failure-hook command.
    /// Only rendered for repository scopes (`isRepo == true`).
    var failureHookSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Failure Hook")
            infoCard {
                hookToggleRow
                Divider().padding(.leading, RBSpacing.md)
                branchRow
                Divider().padding(.leading, RBSpacing.md)
                localPathRow
                Divider().padding(.leading, RBSpacing.md)
                commandRow
            }
        }
    }
}

// MARK: - Failure Hook Rows
/// Row views for the failure-hook toggle and branch-filter picker.
extension ScopeEditSheet {
    /// Toggle row enabling or disabling the failure-hook for this scope.
    /// Updates draft state only — not persisted until Save.
    var hookToggleRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Call this terminal call on failure detection")
                    .font(.system(size: 12, weight: .medium))
                Text("This will call terminal with a call of your choosing. Can be used for AI auto-recovery.")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $hookEnabled)
                .toggleStyle(.switch)
                .tint(Color.rbSuccess)
                .labelsHidden()
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 10)
    }

    /// Row for selecting the branch filter applied by the failure hook.
    /// Tapping opens `BranchSelectorSheet`; an ×-button clears the draft filter.
    var branchRow: some View {
        Button { showBranchSheet = true } label: {
            HStack(spacing: 8) {
                Text("Branch")
                    .font(.system(size: 12))
                    .foregroundColor(Color.rbTextSecondary)
                    .frame(width: 100, alignment: .leading)
                    .fixedSize()
                if let branch = hookBranch {
                    Text(branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.rbTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: clearBranchFilter) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color.rbTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear branch filter")
                } else {
                    Text("All branches")
                        .font(.system(size: 11))
                        .foregroundColor(Color.rbTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(Color.rbTextTertiary)
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Row for setting the local repository path used by the failure hook.
    /// Supports inline text editing and an NSOpenPanel folder-picker.
    var localPathRow: some View {
        HStack(spacing: 8) {
            Text("Local Path")
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading)
                .fixedSize()
            if isEditingPath {
                TextField("~/code/org/repo", text: $localRepoPath) // NOSONAR — UI placeholder text, not a configurable URI
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.plain)
                    .foregroundColor(Color.rbTextPrimary)
                    .frame(maxWidth: .infinity)
                    .onSubmit { commitLocalPath() }
                Button("Done") { commitLocalPath() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.rbAccent)
            } else {
                Button {
                    log("[PICKER] localPathRow — text button tapped, calling startEditingPath")
                    startEditingPath()
                } label: {
                    Text(localRepoPath.isEmpty ? "Tap to set path…" : localRepoPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(localRepoPath.isEmpty ? Color.rbTextTertiary : Color.rbTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Button(action: {
                    log("[PICKER] localPathRow — folder button tapped, calling openFolderPicker")
                    openFolderPicker()
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(Color.rbTextSecondary)
                }
                .buttonStyle(.plain)
                .help("Browse for folder…")
                if !localRepoPath.isEmpty {
                    // Clears draft only — not persisted until Save.
                    Button(action: { localRepoPath = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color.rbTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear local path")
                }
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 9)
    }

    /// Row for configuring the hook command. Tapping opens
    /// `FailureHookCommandSheet` where the user can enter or edit the command.
    var commandRow: some View {
        Button { showHookSheet = true } label: {
            HStack(spacing: 8) {
                Text("Command")
                    .font(.system(size: 12))
                    .foregroundColor(Color.rbTextSecondary)
                    .frame(width: 100, alignment: .leading)
                    .fixedSize()
                if !hookCommand.isEmpty {
                    Text(hookCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.rbTextPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Tap to set a command…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.rbTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(Color.rbTextTertiary)
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Actions
/// User-initiated actions: path editing, save, and cancel.
extension ScopeEditSheet {
    /// Enters inline editing mode for the local-path field, pre-filling `~/`
    /// if the path is currently empty.
    func startEditingPath() {
        if localRepoPath.isEmpty { localRepoPath = "~/" }
        isEditingPath = true
    }

    /// Normalises the draft local path: trims whitespace and clears the `~/` placeholder.
    /// Does NOT write to `ScopePreferencesStore` — that happens in `confirmSave()`.
    func commitLocalPath() {
        isEditingPath = false
        let trimmed = localRepoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        localRepoPath = (trimmed == "~/") ? "" : trimmed
    }

    /// Clears the draft branch filter. Does NOT write to `ScopePreferencesStore`.
    func clearBranchFilter() {
        hookBranch = nil
    }

    /// Single commit point: atomically reads, mutates, and writes the `ScopePreferences`
    /// blob via `modifyPreferences(for:with:)` — a single actor hop that eliminates
    /// the TOCTOU window of the former two-hop `preferences(for:)` + `setPreferences(_:for:)`
    /// pattern warned about in P10 and the store's own doc comment.
    ///
    /// Fields not editable in this sheet (alias, pollingInterval, notifyOnSuccess,
    /// notifyOnFailure) are preserved automatically because `modifyPreferences` starts
    /// from the live stored blob and the closure only touches the four fields above.
    ///
    /// After saving, calls `scopeStore.refreshDisplayNames()` so `ScopesView` reflects
    /// any alias change immediately without an app restart. (#1538)
    ///
    /// ## Isolation note (P9)
    /// `@MainActor` state (`hookEnabled`, `hookBranch`, `hookCommand`, `localRepoPath`)
    /// cannot be read inside the actor-isolated `modifyPreferences` closure. All four
    /// are captured into locals before the `await` so the closure is free of any
    /// `@MainActor` references and the compiler is satisfied.
    ///
    /// Called via `Task { await confirmSave() }` in `buttonFooter` — a plain
    /// (non-detached) Task that inherits `@MainActor` from the SwiftUI button
    /// context, so `isPresented = false` after the await still runs on
    /// `@MainActor` with no isolation gap. (P9)
    @MainActor func confirmSave() async {
        let command = hookCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let path    = localRepoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        // Capture @MainActor state before the actor hop — the modifyPreferences
        // closure runs inside the actor and cannot access @MainActor properties directly.
        let enabled = hookEnabled
        let branch  = hookBranch
        await ScopePreferencesStore.shared.modifyPreferences(for: scope) { prefs in
            prefs.failureHookEnabled = enabled
            prefs.failureHookBranch  = branch
            prefs.failureHookCommand = command.isEmpty ? nil : command
            prefs.localRepoPath      = path.isEmpty    ? nil : path
        }
        // Refresh cached display names so ScopesView reflects the newly saved alias
        // immediately after the sheet closes, without requiring an app restart. (#1538)
        await scopeStore.refreshDisplayNames()
        isPresented = false
    }

    /// Presents an `NSOpenPanel` as a sheet attached to the popover's own window.
    ///
    /// Uses `beginSheetModal(for:)` so the panel attaches as a child sheet.
    /// AppKit never considers clicks inside the sheet as "outside clicks",
    /// so the popover is never dismissed during the picker session. (#1195)
    ///
    /// The host window reference is captured early by `WindowGrabber` (attached in
    /// `body`) so there is no key-window race at call time.
    func openFolderPicker() {
        let delegate = NSApp.delegate as? AppDelegate
        log("[PICKER] openFolderPicker — ENTER hostWindow=\(String(describing: hostWindow)) panelIsOpen=\(delegate?.panelIsOpen ?? false)")

        guard let window = hostWindow else {
            log("[PICKER] openFolderPicker — ERROR: hostWindow is nil — picker will NOT open. popoverWindow=\(String(describing: delegate?.popover?.contentViewController?.view.window))")
            return
        }

        log("[PICKER] openFolderPicker — window OK: \(window) isKey=\(window.isKeyWindow) isVisible=\(window.isVisible) sheets=\(window.sheets.count)")

        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = "Select"
        picker.message = "Choose the local folder for \(scope)"
        if !localRepoPath.isEmpty {
            let expanded = NSString(string: localRepoPath).expandingTildeInPath
            picker.directoryURL = URL(fileURLWithPath: expanded)
        } else {
            picker.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        log("[PICKER] openFolderPicker — calling beginSheetModal on window")
        picker.beginSheetModal(for: window) { response in
            log("[PICKER] openFolderPicker — completion: response=\(response.rawValue) panelIsOpen=\(delegate?.panelIsOpen ?? false)")
            if response == .OK, let url = picker.url {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let abs = url.path
                let tilde: String
                if abs == home {
                    tilde = "~/"
                } else if abs.hasPrefix(home + "/") {
                    tilde = "~/" + abs.dropFirst(home.count + 1)
                } else {
                    tilde = abs
                }
                log("[PICKER] openFolderPicker — user picked path=\(tilde)")
                localRepoPath = tilde
            } else {
                log("[PICKER] openFolderPicker — user cancelled or no URL")
            }
        }
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

// swiftlint:disable:this file_length
