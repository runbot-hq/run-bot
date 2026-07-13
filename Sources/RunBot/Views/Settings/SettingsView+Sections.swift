// SettingsView+Sections.swift
// RunBot
import AppUpdater
import RunBotCore
import SwiftUI

// MARK: - SettingsView sections extension
/// Settings sections broken out from `SettingsView` for readability.
internal extension SettingsView {

    // MARK: - Account
    /// GitHub sign-in / sign-out controls and authentication status.
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
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Authenticated")
                                    .font(.caption)
                                    .foregroundColor(Color.rbTextSecondary)
                                Text("via env token")
                                    .font(.caption2)
                                    .foregroundColor(Color.rbTextTertiary)
                            }
                        }
                        Button(action: signInWithGitHub) {
                            Text("Sign in with GitHub").font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .help("Authorize RunBot via GitHub OAuth and store token in Keychain")
                    }
                } else {
                    Button(action: signInWithGitHub) {
                        Text("Sign in with GitHub").font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .help("Authorize RunBot via GitHub OAuth and store token in Keychain")
                }
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 8)
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
                    Text("Start, stop, edit, and remove self-hosted runners on this machine.")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
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
                    Text("Add, remove, and configure GitHub repos or orgs to monitor.")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
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
    /// General section: polling interval, API call counter, notification toggles, launch-at-login, popover arrow, and beta channel.
    ///
    /// `settings` and `notifications` are injected `let` properties on an `@Observable` type.
    /// SwiftUI cannot synthesise `$`-bindings from plain `let` stored properties, so we
    /// capture each store in a local `Bindable` wrapper before using `$` syntax.
    var generalSection: some View {
        let bindableSettings      = Bindable(settings)
        let bindableNotifications = Bindable(notifications)
        return VStack(alignment: .leading, spacing: 0) {
            Text("General").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Polling interval").font(.system(size: 12)); Spacer()
                Text("\(settings.pollingInterval)s").font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                    .frame(minWidth: 36, alignment: .trailing)
                Stepper("", value: bindableSettings.pollingInterval, in: 10...300).labelsHidden()
            }
            .padding(.horizontal, RBSpacing.md).padding(.top, 6).padding(.bottom, 2)
            Text("How often RunBot checks GitHub for runner and workflow status. Lower values use more API quota.")
                .font(.caption).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
            APICallCounterRow(resetDate: runnerState.rateLimitResetDate)
                .font(.system(size: 12))
                .padding(.horizontal, RBSpacing.md)
                .padding(.vertical, 8)
            HStack {
                Text("Notify on success").font(.system(size: 12)); Spacer()
                Toggle("", isOn: bindableNotifications.notifyOnSuccess)
                    .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
            HStack {
                Text("Notify on failure").font(.system(size: 12)); Spacer()
                Toggle("", isOn: bindableNotifications.notifyOnFailure)
                    .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
            HStack {
                Text("Launch at login").font(.system(size: 12)); Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
                    .onChange(of: launchAtLogin) { _, newVal in applyLaunchAtLogin(newVal) }
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
            popoverArrowRow
            Divider().padding(.leading, RBSpacing.md)
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
    var betaChannelRow: some View {
        let bindableBeta = Bindable(settings)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Beta channel").font(.system(size: 12))
                Text("Receive pre-release builds for early access to new features. Takes effect on the next update check.")
                    .font(.caption2).foregroundColor(Color.rbTextSecondary)
            }
            Spacer()
            Toggle("", isOn: bindableBeta.betaChannel)
                .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 6).padding(.bottom, 6)
    }

    // MARK: - About
    /// App version, build number, and update available banner (when a newer release exists).
    var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("About").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Version").font(.system(size: 12)); Spacer()
                Text("\(appVersion) (\(appBuild))").font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
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
