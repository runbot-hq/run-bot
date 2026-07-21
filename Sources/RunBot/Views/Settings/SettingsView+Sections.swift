// SettingsView+Sections.swift
// RunBot
import AppUpdater
import RunBotCore
import SwiftUI

// MARK: - SettingsView sections extension
/// Settings sections broken out from `SettingsView` for readability.
internal extension SettingsView {

    // MARK: - Account
    /// GitHub sign-in / sign-out controls, authentication status, and API call counter.
    var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("GitHub").font(.system(size: 12))
                if isSigningIn {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Waiting for browser…").font(.caption).foregroundColor(Color.rbTextSecondary)
                    }
                } else if isOAuthAuthenticated {
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.rbSuccess).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Authenticated")
                                    .font(.caption)
                                    .foregroundColor(Color.rbTextSecondary)
                                Text("via OAuth")
                                    .font(.caption2)
                                    .foregroundColor(Color.rbTextTertiary)
                            }
                        }
                        Button(action: signOutOfGitHub) {
                            Text("Sign out").font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.rbDanger)
                        .help("Remove OAuth token from Keychain. GH_TOKEN / GITHUB_TOKEN env vars used as fallback if available.")
                    }
                } else if isCLIAuthenticated {
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.rbSuccess).frame(width: 7, height: 7)
                            // Single-line: collapsed from two stacked Text views (#2082)
                            Text("Authenticated via env token")
                                .font(.caption)
                                .foregroundColor(Color.rbTextSecondary)
                        }
                        Spacer()
                        Button(action: signInWithGitHub) {
                            Text("Sign in with GitHub").font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .help("Authorize RunBot via GitHub OAuth and store token in Keychain")
                    }
                } else {
                    // Unauthenticated — no status dot (there is no auth state to indicate).
                    // The Circle() indicator present in the OAuth and CLI branches is
                    // intentionally absent here. This is not a missing element.
                    HStack {
                        Spacer()
                        Button(action: signInWithGitHub) {
                            Text("Sign in with GitHub").font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .help("Authorize RunBot via GitHub OAuth and store token in Keychain")
                    }
                }
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 8)
            Divider().padding(.leading, RBSpacing.md)
            // API call counter: title row first, description caption below.
            APICallCounterRow()
                .font(.system(size: 12))
                .padding(.horizontal, RBSpacing.md)
                .padding(.top, 8)
                .padding(.bottom, 2)
            Text("Tracks GitHub API requests consumed in the current rate-limit window.")
                .font(.caption2)
                .foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md)
                .padding(.bottom, 8)
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
                StatusCountBadge(label: runnerCountLabel)
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
                StatusCountBadge(label: scopeCountLabel)
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

    // MARK: - Management count labels

    /// "N active, M inactive" label for the local runners row, or "" when none configured.
    ///
    /// Sources from `runnerState.localRunners` (via `AppState`) — runners flow through
    /// `RunnerState` because their lifecycle is managed by `LocalRunnerStore`. This is
    /// intentionally different from `scopeCountLabel`, which reads from the injected
    /// `scopeStore` directly. Both stores are `@Observable` so SwiftUI reactivity works
    /// correctly for both — the asymmetry reflects domain ownership, not an oversight.
    var runnerCountLabel: String {
        let runners = runnerState.localRunners
        guard !runners.isEmpty else { return "" }
        let active = runners.filter { $0.isRunning }.count
        let inactive = runners.count - active
        return "\(active) active, \(inactive) inactive"
    }

    /// "N active, M inactive" label for the scopes row, or "" when none configured.
    ///
    /// Sources from the injected `scopeStore` — scopes are not part of `RunnerState`
    /// so they cannot be reached via `runnerState`. See `runnerCountLabel` for the
    /// full explanation of why these two labels use different sources.
    var scopeCountLabel: String {
        let entries = scopeStore.entries
        guard !entries.isEmpty else { return "" }
        let active = entries.filter { $0.isEnabled }.count
        let inactive = entries.count - active
        return "\(active) active, \(inactive) inactive"
    }

    // MARK: - General
    /// General section: notification toggles, launch-at-login, popover arrow, and beta channel.
    ///
    /// The polling interval row was removed in #2069 — RunnerPoller now drives its own
    /// cadence via `PollIntervalStrategy` and no longer reads `pollingInterval` from
    /// `AppPreferencesStore`. The underlying preference key is retained for potential
    /// future use (e.g. per-scope overrides) but is no longer surfaced in the UI.
    ///
    /// The API call counter row was moved to `accountSection` in #2082 — it is semantically
    /// tied to the authenticated GitHub token, not to general app preferences.
    ///
    /// `settings` and `notifications` are injected `let` properties on an `@Observable` type.
    /// SwiftUI cannot synthesise `$`-bindings from plain `let` stored properties, so we
    /// capture each store in a local `Bindable` wrapper before using `$` syntax.
    ///
    /// Notifications and Launch at login rows use `VStack(title + subtitle)` on the left
    /// and the control right-aligned, matching the pattern used by `betaChannelRow` and
    /// `popoverArrowRow`. The Notifications `Picker` uses `.fixedSize()` rather than a
    /// hardcoded `.frame(width:)` so its width is always derived from the selected item
    /// label — avoids the narrow-on-first-render flakiness caused by width being measured
    /// before the selected item string was known.
    var generalSection: some View {
        let bindableNotifications = Bindable(notifications)
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
                // .fixedSize() lets the picker measure its own intrinsic width from the
                // selected item label. A hardcoded .frame(width:) fights SwiftUI's
                // menu-picker measurement and produces a narrow control on first render.
                Picker("Notifications", selection: bindableNotifications.notificationMode) {
                    ForEach(NotificationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
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
                    .onChange(of: launchAtLogin) { _, newVal in applyLaunchAtLogin(newVal) }
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
    /// Toggle row that shows or hides the NSPopover anchor arrow.
    ///
    /// Uses a local `Bindable` wrapper for the same reason as `generalSection`.
    var popoverArrowRow: some View {
        let bindableSettings = Bindable(settings)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show popover arrow").font(.system(size: 12))
                Text("Controls whether the anchor arrow is shown on the menu bar popover. Takes effect on next open.")
                    .font(.caption2).foregroundColor(Color.rbTextSecondary)
            }
            Spacer()
            Toggle("", isOn: bindableSettings.showPopoverArrow)
                .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
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
    /// `.onChange(of: settings.betaChannel)` (not `bindableBeta.betaChannel.wrappedValue`)
    /// is the correct observation target — `settings` is the underlying `@Observable` store.
    /// On every toggle direction:
    ///   1. The cached zip at `<schedulerIdentifier>/update.zip` is deleted so
    ///      `checkAndHandle` cannot skip the download and jump straight to `.ready` with a
    ///      stale (potentially wrong-channel) zip already on disk.
    ///      `autoUpdater.schedulerIdentifier` is used directly so the path stays in sync
    ///      if the identifier ever changes — a hardcoded copy would silently break.
    ///   2. `checkAndHandle` is called immediately — no waiting for the background scheduler.
    ///      `apply(.idle)` is intentionally NOT called before the task (#2168): doing so
    ///      collapses `aboutSection`'s `currentPhase != .idle` guard synchronously, tearing
    ///      down `updateActionRow` before the async check can call `apply(.available)`.
    ///      `checkAndHandle` drives state to the correct terminal phase itself — the
    ///      pre-reset was redundant and the source of the install-button-never-appears bug.
    var betaChannelRow: some View {
        let bindableBeta = Bindable(settings)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Beta channel").font(.system(size: 12))
                Text("Receive pre-release builds for early access to new features. Only affects which updates are offered — does not change your currently installed version.")
                    .font(.caption2).foregroundColor(Color.rbTextSecondary)
            }
            Spacer()
            Toggle("", isOn: bindableBeta.betaChannel)
                .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
                .onChange(of: settings.betaChannel) { _, _ in
                    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                    let zip = caches?.appendingPathComponent(autoUpdater.schedulerIdentifier)
                                     .appendingPathComponent("update.zip")
                    zip.map { try? FileManager.default.removeItem(at: $0) }
                    Task { await autoUpdater.checkAndHandle(state: runnerState) }
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
        HStack(spacing: 8) {
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
                // The download fires automatically — the user never taps a Download
                // button. This matches the macOS/Sparkle convention: downloading is
                // low-risk and reversible (a cached zip), so consent is only required
                // at install. Do NOT add a Download button here (Principle 5:
                // unsupported is correct). The disabled Install & Relaunch button is
                // the in-progress signal — it becomes active when .ready is reached.
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
                // compiler exhaustiveness. Do NOT add an isDownloading: Bool flag to
                // RunnerState to make this reachable — that violates Principle 1 (one
                // enum owns all state) and Principle 4 (no sprawl). If download
                // progress UI is ever genuinely needed, the right fix is a
                // downloading(version: String, progress: Double) case on UpdatePhase.
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available: \(version)").font(.system(size: 12))
                    // ProgressView label is intentionally visible (not hidden) so VoiceOver
                    // announces "Downloading update…" — spec #1797 acceptance criterion.
                    // Do NOT add .labelsHidden() here.
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
                    Task {
                        await autoUpdater.installAndRelaunch(state: runnerState)
                    }
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
                // Retry re-runs the full pipeline from scratch (check → download →
                // verify → cache). There is no partial resume, no saved download
                // offset, no rehydration of prior state. Principle 2: binary outcomes
                // only. If the retry succeeds it reaches .ready; if it fails again
                // it returns here. The user retries until it works or gives up.
                Button("Retry") {
                    Task {
                        await autoUpdater.checkAndHandle(state: runnerState)
                    }
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
/// Renders nothing when `label` is empty — no space is consumed for unconfigured rows.
/// Used in `manageLocalRunnersRow` and `manageScopesRow` (#2082).
///
/// ## Color rationale
/// Foreground uses `.primary` (black in light mode, white in dark mode) rather than
/// a hardcoded `.white`. `Color.rbTextTertiary` is `Color(white: 0.58)` in light mode
/// — white-on-0.58-gray is ~2.3:1 contrast, well below the WCAG 4.5:1 minimum and
/// near-invisible in light mode. Background uses `Color.rbTextTertiary.opacity(0.18)`
/// — a faint tint that matches the `Color.rbTextTertiary.opacity(0.22)` pattern already
/// used by `InlineJobRowsView` for progress track fills. No new design token is introduced.
/// ❌ Do NOT change foreground back to `.white` — it breaks contrast in light mode.
private struct StatusCountBadge: View {
    /// The formatted string to display, e.g. "2 active, 1 inactive".
    /// Pass an empty string to suppress the badge entirely — no layout space is consumed.
    let label: String
    /// Renders a capsule pill with `label` text, or nothing when `label` is empty.
    var body: some View {
        if !label.isEmpty {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.rbTextTertiary.opacity(0.18)))
        }
    }
}
