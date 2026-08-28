// StepLogView.swift
// RunBot
import AppKit
import GitHubClient
import RunBotCore
import SwiftUI

// ╔════════════════════════════════════════════════════════════════════════════╗
// ║ StepLogView — SUPERSEDED. Not reachable from the windowed shell.          ║
// ╠════════════════════════════════════════════════════════════════════════════╣
// ║ This view was navigation level 3 of the menu-bar popover stack, pushed by ║
// ║ a rootView swap on the old AppDelegate. That stack no longer exists: the  ║
// ║ live path is                                                              ║
// ║   AppNavigationSplitView → AppDetailColumnView → StepLogPaneView          ║
// ║   → StepLogContentView                                                    ║
// ║ and this type has no remaining call site (Periphery reports it unused).   ║
// ║                                                                            ║
// ║ ⚠️ The LAYOUT + SIZING CONTRACT that used to live here has been MIGRATED  ║
// ║ to `StepLogContentView.body`, restated for the windowed shell. Read it    ║
// ║ there, not here. Nothing is lost if this file is deleted — see the        ║
// ║ dead-code cleanup issues (#3027 / #3028).                                 ║
// ╙────────────────────────────────────────────────────────────────────────────╜
/// Shows the raw log text for a single `GitHubStep`, wrapped in a back-navigation
/// header.
///
/// Superseded by `StepLogPaneView` in the windowed shell and retained only until
/// the dead-code cleanup lands. `ScrollView` absorbs overflow; the fetch lifecycle
/// belongs to the embedded `StepLogContentView`.
@MainActor
struct StepLogView: View {
    /// The job that owns this step.
    let job: ActiveJob
    /// The step whose log will be displayed.
    let step: GitHubStep
    /// Called when the user taps the back button.
    let onBack: () -> Void
    /// Optional callback fired on the main thread once the async log fetch completes.
    ///
    /// Do NOT call setFrameSize / contentSize directly from this closure.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    var onLogLoaded: (() -> Void)?
    /// Injected scope store — avoids `ScopeStore.shared` singleton access inside `loadLog`.
    /// Defaults to the live singleton so all existing call sites require no changes.
    var scopeStore: any ScopeStoreProtocol
    /// Bound to the scene-owned `LogFetcher` so the ZIP cache survives across
    /// step taps. Threading it down via `@Binding` keeps the ZIP cache alive for
    /// the lifetime of the scene; the snapshot/writeback pattern in
    /// `StepLogContentView.loadLog()` propagates updates back.
    @Binding var logFetcher: LogFetcher

    /// Creates a `StepLogView` for the given job step.
    /// - Parameters:
    ///   - job: The job that owns the step.
    ///   - step: The step whose log will be fetched and displayed.
    ///   - logFetcher: Binding to the scene-owned `LogFetcher`, so the ZIP cache
    ///     survives remounts. The `.constant(LogFetcher())` default is for previews
    ///     and tests only — writes through a `.constant` binding are silently
    ///     dropped, so every cache update would be lost.
    ///   - onBack: Called when the user taps the back button.
    ///   - onLogLoaded: Optional callback fired on the main thread once the log fetch completes.
    ///   - scopeStore: Scope store used for API scope resolution. Defaults to `ScopeStore.shared`.
    init(
        job: ActiveJob,
        step: GitHubStep,
        logFetcher: Binding<LogFetcher> = .constant(LogFetcher()), // preview/test only — production callers must pass the scene's @Binding; .constant writes are silently dropped
        onBack: @escaping () -> Void,
        onLogLoaded: (() -> Void)? = nil,
        scopeStore: (any ScopeStoreProtocol)? = nil
    ) {
        self.job = job
        self.step = step
        self._logFetcher = logFetcher
        self.onBack = onBack
        self.onLogLoaded = onLogLoaded
        self.scopeStore = scopeStore ?? ScopeStore.shared
    }

    /// Root body: panel navigation header + reusable log content.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Panel-specific back-navigation header.
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Steps").font(.caption)
                    }
                    .foregroundColor(Color.rbTextSecondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.top, 10)
            .padding(.bottom, 2)

            // Reusable step-log content (fetch, render, toolbar, metadata).
            // ⚠️ .frame(maxHeight:) cap is REQUIRED here (ref #370).
            // ❌ NEVER remove .frame(maxHeight:) from this view.
            StepLogContentView(
                job: job,
                step: step,
                logFetcher: $logFetcher,
                onLogLoaded: onLogLoaded,
                scopeStore: scopeStore
            )
            // ⚠️ REQUIRED — caps reported height. See the SIZING CONTRACT on
            // `StepLogContentView.body` for the canonical rule (ref #370).
            // ❌ NEVER remove this modifier.
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        // ⚠️ Mirrors the SIZING CONTRACT on `StepLogContentView.body`, which is the
        // canonical copy. Do not edit these constraints here in isolation.
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
    }
}
