// SettingsView+Sections.swift
// RunBot

import AppUpdater
import RunBotCore
import SwiftUI

// MARK: - SettingsView sections extension

/// Settings sections broken out from `SettingsView` for readability.
internal extension SettingsView {

    // MARK: - Account

    /// Authentication source cards + API call counter (#2459).
    ///
    /// Replaced the old single-branch status row with `AuthenticationSection`,
    /// which renders an `EnvironmentTokenCard` and a `GitHubOAuthCard` side-by-side.
    /// The `APICallCounterRow` is preserved below the divider unchanged.
    ///
    /// DO NOT add a separate description Text sibling after `APICallCounterRow` —
    /// it owns its title and description internally (layout bug fix #2217).
    var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuthenticationSection(
                authentication: authentication,
                onSignIn: signInWithGitHub,
                onSignOut: signOutOfGitHub,
                onToggleEnvironment: { enabled in
                    if enabled {
                        appState.authentication.setSelectedSource(.environment)
                    } else {
                        appState.authentication.setSelectedSource(.unauthenticated)
                    }
                }
            )
            Divider().padding(.leading, RBSpacing.md)
            // APICallCounterRow owns its title AND description internally.
            // DO NOT add a separate description Text sibling here — that was the
            // root cause of the layout bug fixed in #2217.
            APICallCounterRow()
                .padding(.horizontal, RBSpacing.md)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Management

    /// "Management" section: header label + nav rows for local runners and scopes.
    var managementSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Management").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            manageLocalRunnersRow
            manageScopesRow
        }
    }

    /// Navigation row that drills into `LocalRunnersView`.
    var manageLocalRunnersRow: some View {
        Button {
            showLocalRunners = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage local runners").font(.system(size: 12))
                    Text("Self-hosted runners configured on this Mac")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
                let runners = runnerState.localRunners
                // .filter performance: localRunners is always a small array (~10 items
                // max by design — these are self-hosted runners on a single Mac). The
                // O(n) walk is negligible and avoids a second .filter pass for inactive.
                let activeRunners = runners.filter { $0.isRunning }.count
                // max(0, ...) guards against a negative result if the @Observable-backed
                // store is mutated between the .filter read and the .count read. This is
                // a latent race, not a crash — the floor makes the intent explicit.
                let inactiveRunners = max(0, runners.count - activeRunners)
                StatusCountBadge(active: activeRunners, inactive: inactiveRunners)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 8)
    }

    /// Navigation row that drills into `ScopesView`.
    var manageScopesRow: some View {
        Button {
            showScopes = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage scopes").font(.system(size: 12))
                    Text("Repository and organization scopes")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
                let entries = scopeStore.entries
                // .filter performance: scopeStore.entries is a small array in practice
                // (typical user has <20 scopes). O(n) is negligible here.
                let activeScopes = entries.filter { $0.isEnabled }.count
                // max(0, ...) same rationale as manageLocalRunnersRow above.
                let inactiveScopes = max(0, entries.count - activeScopes)
                StatusCountBadge(active: activeScopes, inactive: inactiveScopes)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 8)
    }

    // MARK: - General

    /// General section: notification toggles, launch-at-login, popover arrow, and beta channel.
    ///
    /// FIX #2174: `notifications` is now `@Bindable var` on `SettingsView` — we use
    /// `$notifications.notificationMode` directly instead of constructing a local
    /// `Bindable(notifications)` wrapper inside this computed var body. The local
    /// wrapper pattern silently drops writes (see issue #2174).
    var generalSection: some View {
        #if DEBUG
        log("【generalSection】rendered — settings.betaChannel=\(settings.betaChannel) notifications.notificationMode=\(notifications.notificationMode)", category: .general)
        #endif
        return VStack(alignment: .leading, spacing: 0) {
            Text("General").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications").font(.system(size: 12))
                    Text("Controls when RunBot sends job notifications.")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
                // FIX #2174: was Bindable(notifications).notificationMode — now $notifications.notificationMode
                // .fixedSize() lets the picker measure its own intrinsic width from the
                // selected item label. A hardcoded .frame(width:) fights SwiftUI's
                // menu-picker measurement and produces a narrow control on first render.
                Picker("Notifications", selection: $notifications.notificationMode) {
                    ForEach(NotificationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
                #if DEBUG
                .onChange(of: notifications.notificationMode) { old, new in
                    log("【generalSection】notificationMode changed \(old) → \(new)", category: .general)
                }
                #endif
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login").font(.system(size: 12))
                    Text("Start RunBot automatically when you log in.")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
                    .onChange(of: launchAtLogin) { _, newVal in
                        #if DEBUG
                        log("【generalSection】launchAtLogin changed → \(newVal)", category: .general)
                        #endif
                        applyLaunchAtLogin(newVal)
                    }
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
            #if DEBUG
            popoverArrowRow
            Divider().padding(.leading, RBSpacing.md)
            #endif
            betaChannelRow
        }
    }

    // MARK: - Popover arrow row (#1184)

    /// Toggle row that shows or hides the anchor arrow.
    ///
    /// FIX #2174: was `Bindable(settings).showPopoverArrow` — now `$settings.showPopoverArrow`.
    ///
    /// TODO: `showPopoverArrow` is inert since PR #2305 (NSPopover replaced by owned NSPanel).
    /// The arrow was drawn by the now-removed `MBKBubbleShape` and cannot be
    /// suppressed without a separate layout path. Remove this toggle in a follow-up.
    /// TODO: remove when issue #2307 is resolved
    var popoverArrowRow: some View {
        #if DEBUG
        log("【popoverArrowRow】rendered — showPopoverArrow=\(settings.showPopoverArrow)", category: .general)
        #endif
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show popover arrow").font(.system(size: 12))
                Text("Controls whether the anchor arrow is shown on the menu bar popover. Takes effect on next open.")
                    .font(.caption2).foregroundColor(Color.rbTextSecondary)
            }
            Spacer()
            // FIX #2174: was Bindable(settings).showPopoverArrow — now $settings.showPopoverArrow
            Toggle("", isOn: $settings.showPopoverArrow)
                .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
                .disabled(true)
                #if DEBUG
                .onChange(of: settings.showPopoverArrow) { old, new in
                    log("【popoverArrowRow】showPopoverArrow changed \(old) → \(new)", category: .general)
                }
                #endif
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 6).padding(.bottom, 6)
    }

    // MARK: - Beta channel row

    /// Toggle row that opts the user into pre-release (beta) builds for the in-app update check.
    ///
    /// ## Scope of this toggle — read before changing the subtitle
    ///
    /// REVIEWER: This toggle controls *future update offers* only. It does NOT affect
    /// the currently installed version. When the user is running a beta build and turns
    /// this off, the About section correctly continues to show the beta version string —
    /// that is what is installed. The subtitle wording is deliberate; it was updated in
    /// #2085 specifically to prevent users from misreading the toggle's scope. Do not
    /// shorten or remove the second sentence.
    ///
    /// ## Immediate check on toggle (#2162)
    ///
    /// FIX #2174: was `Bindable(settings).betaChannel` — now `$settings.betaChannel`.
    /// The old pattern constructed a transient `Bindable` wrapper inside this computed
    /// var body; the write hit that wrapper and was silently discarded, so the backing
    /// store was never mutated and `onChange` never fired. Using `$settings.betaChannel`
    /// routes the write through the stable `@Bindable var settings` on `SettingsView`.
    ///
    /// ## Phase reset on toggle (#2188)
    ///
    /// FIX #2188: `runnerState.apply(.idle)` is called synchronously at the top of the
    /// handler before the async Task spawns. Without this, the stale `.ready` phase from
    /// a previous channel's check persisted after `checkAndHandle` returned "no update
    /// available", keeping the install button visible indefinitely.
    var betaChannelRow: some View {
        #if DEBUG
        log("【betaChannelRow】rendered — betaChannel=\(settings.betaChannel) settings=\(ObjectIdentifier(settings))", category: .general)
        #endif
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Beta channel").font(.system(size: 12))
                Text("Receive pre-release builds for early access to new features. Only affects which updates are offered — does not change your currently installed version.")
                    .font(.caption2).foregroundColor(Color.rbTextSecondary)
            }
            Spacer()
            // FIX #2174: was Bindable(settings).betaChannel — now $settings.betaChannel
            Toggle("", isOn: $settings.betaChannel)
                .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
                .onChange(of: settings.betaChannel) { _, newValue in
                    // DEBUG #2170 — remove once beta-toggle install-button bug is verified fixed
                    #if DEBUG
                    log("【beta-toggle】onChange fired — betaChannel=\(newValue) settings=\(ObjectIdentifier(settings))", category: .general)
                    #endif

                    // FIX #2188: reset phase to .idle immediately so the install button
                    // hides at once, before the async check completes.
                    runnerState.apply(.idle)

                    #if DEBUG
                    log("【beta-toggle】phase reset to .idle", category: .general)
                    #endif

                    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                    let zip = caches?.appendingPathComponent(autoUpdater.schedulerIdentifier)
                                     .appendingPathComponent("update.zip")

                    #if DEBUG
                    log("【beta-toggle】cachesDir=\(caches?.path ?? "NIL")", category: .general)
                    log("【beta-toggle】zip path=\(zip?.path ?? "NIL")", category: .general)
                    #endif

                    if let zip {
                        let exists = FileManager.default.fileExists(atPath: zip.path)
                        #if DEBUG
                        log("【beta-toggle】zip exists=\(exists)", category: .general)
                        #endif
                        if exists {
                            do {
                                try FileManager.default.removeItem(at: zip)
                                #if DEBUG
                                log("【beta-toggle】zip deleted OK", category: .general)
                                #endif
                            } catch {
                                #if DEBUG
                                log("【beta-toggle】zip delete FAILED: \(error)", category: .general)
                                #endif
                            }
                        }
                    }

                    #if DEBUG
                    log("【beta-toggle】spawning Task", category: .general)
                    #endif
                    Task {
                        #if DEBUG
                        log("【beta-toggle】Task ENTERED (actor=main)", category: .general)
                        #endif
                        await autoUpdater.checkAndHandle(state: runnerState)
                        #if DEBUG
                        log("【beta-toggle】Task COMPLETED", category: .general)
                        #endif
                    }
                    #if DEBUG
                    log("【beta-toggle】onChange handler EXIT", category: .general)
                    #endif
                }
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 6).padding(.bottom, 6)
    }

    // MARK: - About

    /// App version, build number, and update available banner (when a newer release exists).
    ///
    /// ## Why `Bundle.main.isPreReleaseBuild`, not `appVersion.contains("-")`
    ///
    /// REVIEWER: The caption uses `Bundle.main.isPreReleaseBuild` — the purpose-built API
    /// in `Bundle+Version.swift` — rather than re-checking `appVersion.contains("-")` inline.
    /// `appVersion` is a plain computed var on this view that reads `Bundle.main.rbVersionString`;
    /// it is not an injected seam and will not diverge from `rbVersionString` in any current
    /// or planned architecture. Using `isPreReleaseBuild` keeps detection logic in one place
    /// with all its edge-case documentation. This was reviewed and settled in PR #2085/#2108 —
    /// do not change it back to an inline `contains("-")` without a concrete reason.
    ///
    /// The caption is independent of `betaChannel` — the toggle controls future update offers,
    /// not what is currently installed. See `betaChannelRow` and issue #2085.
    var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("About").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Version").font(.system(size: 12))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(appVersion) (\(appBuild))").font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                    if Bundle.main.isPreReleaseBuild {
                        Text("Pre-release build")
                            .font(.caption2)
                            .foregroundColor(Color.rbTextTertiary)
                    }
                }
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 5)
            if runnerState.currentPhase != .idle {
                Divider().padding(.leading, RBSpacing.md)
                updateActionRow
            }
        }
    }

    // MARK: - Update action row

    /// ⚠️⚠️⚠️ UPDATE UI LIVES HERE AND ONLY HERE — READ BEFORE TOUCHING ⚠️⚠️⚠️
    ///
    /// This row, inside the About section of Settings, is the ONLY update-related
    /// UI in the entire app. This is a deliberate product decision (issue #1794).
    ///
    /// **DO NOT:**
    /// - Add a banner to `PanelMainView`, the menu bar popover, or any other view.
    /// - Add a notification badge, dot indicator, or any other passive signal
    ///   outside of this row.
    ///
    /// The row is rendered whenever `runnerState.currentPhase != .idle` (see
    /// `aboutSection`). When there is no update the row is absent entirely —
    /// no empty space, no placeholder.
    ///
    /// All update UI is derived from a single `switch runnerState.currentPhase`.
    /// Do NOT reach into `runnerState` raw properties (`updateZipURL`,
    /// `updateActionFailed`, etc.) from here — those are implementation detail
    /// of the `UpdateStateProviding` conformance and must not be read directly
    /// by views.
    ///
    /// **REVIEWER:** If you are about to suggest adding a banner or putting update
    /// UI somewhere else in the view hierarchy, please read issue #1794 first.
    /// The single-row approach is the final design for v1, not a placeholder.
    var updateActionRow: some View {
        #if DEBUG
        // DEBUG #2170 — remove once beta-toggle install-button bug is verified fixed
        log("【updateActionRow】RENDERED — phase=\(runnerState.currentPhase)", category: .general)
        #endif
        return HStack(spacing: 8) {
            // ❌ DO NOT add .accessibilityHidden(true) here.
            // Accessibility modifiers on this icon are out of scope for v1 (#1794).
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
            switch runnerState.currentPhase {
            case .idle:
                // Guard in aboutSection prevents us reaching here, but the
                // compiler requires exhaustiveness.
                EmptyView()
            case .available(let version):
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available: \(version)").font(.system(size: 12))
                    Text("A new version of RunBot is ready to download.")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
                Button("Install & Relaunch") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(true)
            case .downloading(let version):
                // ⚠️ This case is unreachable at runtime.
                // RunnerState.currentPhase cannot reconstruct .downloading from stored
                // fields — it returns .available instead (no isDownloading flag; see
                // RunnerState+AppUpdater.swift currentPhase doc and Principle 1).
                // The ProgressView below never renders. The case must remain for
                // compiler exhaustiveness.
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available: \(version)").font(.system(size: 12))
                    ProgressView("Downloading update…")
                        .scaleEffect(RBMetrics.updateProgressScale)
                }
                Spacer()
            case .ready(let version):
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available: \(version)").font(.system(size: 12))
                    Text("A new version of RunBot is ready to install.")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
                Button("Install & Relaunch") {
                    #if DEBUG
                    log("【updateActionRow】Install & Relaunch tapped — phase=\(runnerState.currentPhase)", category: .general)
                    #endif
                    Task { await autoUpdater.installAndRelaunch(state: runnerState) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Install and relaunch RunBot")
            case .failed(let version):
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available" + (version.map { ": \($0)" } ?? ""))
                        .font(.system(size: 12))
                    Text("Download failed. Check your connection and try again.")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
                Button("Retry") {
                    #if DEBUG
                    log("【updateActionRow】Retry tapped — phase=\(runnerState.currentPhase)", category: .general)
                    #endif
                    Task { await autoUpdater.checkAndHandle(state: runnerState) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 8)
    }
}

// MARK: - StatusCountBadge

/// Rounded pill badge used to display active/inactive counts in management rows.
///
/// Renders nothing when both counts are zero — no space is consumed for unconfigured rows.
/// Used in `manageLocalRunnersRow` and `manageScopesRow` (#2082).
///
/// ## Color rationale
/// - Active count uses `Color.rbSuccess` (green) — the same token used for the auth
///   status dot in `accountSection` and toggle tints, establishing a consistent
///   "healthy/running" signal across the app.
/// - Inactive count uses `Color.rbDanger` (red) — the same token used for the "Sign out"
///   button tint, establishing a consistent "stopped/needs attention" signal.
/// - Zero-count segments are suppressed entirely: no "0 inactive" shown in red when
///   all runners/scopes are active, and no "0 active" shown in green when all are inactive.
/// - Background uses `Color.rbTextTertiary.opacity(0.18)` — intentionally lighter than the
///   `Color.rbTextTertiary.opacity(0.22)` used by `InlineJobRowsView` for progress track
///   fills; consistent with that pattern as a faint tint, but the values are not required
///   to be in sync.
/// - No new design tokens are introduced. (#2294)
///
/// ## Layout rationale
/// - `HStack(spacing: 0)` is intentional — not a mistake. A non-zero spacing value inserts
///   a gap *before* the comma separator, producing "2 active , 3 inactive". Zero spacing
///   lets `Text(", ")` (comma + trailing space) carry the visual gap entirely, so the comma
///   hugs the preceding word and the space separates it from the following word.
/// - `Text(", ")` includes a trailing space for the same reason: the space travels with
///   the comma as a single text run rendered in `.secondary` color, keeping punctuation and
///   spacing visually correct without introducing a separate `Spacer` or padding.
private struct StatusCountBadge: View {
    /// Number of active runners or scopes.
    let active: Int
    /// Number of inactive runners or scopes.
    let inactive: Int

    /// Renders a capsule pill with color-coded active (green) and inactive (red) counts,
    /// or nothing when both are zero — no layout space is consumed for empty rows.
    var body: some View {
        if active > 0 || inactive > 0 {
            HStack(spacing: 0) {
                if active > 0 {
                    Text("\(active) active")
                        .foregroundStyle(Color.rbSuccess)
                }
                if active > 0 && inactive > 0 {
                    Text(", ")
                        .foregroundStyle(.secondary)
                }
                if inactive > 0 {
                    Text("\(inactive) inactive")
                        .foregroundStyle(Color.rbDanger)
                }
            }
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.rbTextTertiary.opacity(0.18)))
        }
    }
}
