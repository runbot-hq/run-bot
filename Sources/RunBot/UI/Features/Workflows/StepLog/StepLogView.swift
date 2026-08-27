// StepLogView.swift
// RunBot
import AppKit
import GitHubClient
import RunBotCore
import SwiftUI

// ╔════════════════════════════════════════════════════════════════════════════╗
// ║ ☹️ StepLogView — LAYOUT + SIZING CONTRACT ☹️                              ║
// ╠════════════════════════════════════════════════════════════════════════════╣
// ║ Navigation level 3 (PopoverMainView → JobDetailView → StepLogView).      ║
// ║                                                                            ║
// ║ LAYOUT RULES:                                                              ║
// ║ • Root: .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)     ║
// ║ • idealWidth: 480 hints SwiftUI's initial natural width measurement.      ║
// ║   NSHostingController reads idealWidth as preferredContentSize.width      ║
// ║   on the first layout pass (NSPanel architecture, not NSPopover).         ║
// ║   The panel then resizes to content-driven width via KVO on               ║
// ║   preferredContentSize (see AppDelegate.sizeObservation).                 ║
// ║ • Log content MUST be inside the ScrollView.                              ║
// ║ • Header MUST be outside the ScrollView (always visible, not scrolled).  ║
// ║ ❌ NEVER use .frame(maxWidth: .infinity, maxHeight: .infinity) — the      ║
// ║   maxHeight: .infinity corrupts fittingSize.width when NSHostingCon-      ║
// ║   troller measures the view unconstrained (AppKit bug, see #375 #376)     ║
// ║ ❌ NEVER omit idealWidth: 480 from the root frame                         ║
// ║ ❌ NEVER add .frame(height:) here                                         ║
// ║ ❌ NEVER add .fixedSize() here                                            ║
// ║ ✔ ScrollView MUST have .frame(maxHeight: visibleFrame * 0.75) cap        ║
// ║   Without it, with sizingOptions=.preferredContentSize, SwiftUI           ║
// ║   reports the full log text height as preferredContentSize.height on      ║
// ║   navigate → panel grows off-screen. (ref #370)                           ║
// ║ ❌ NEVER remove the .frame(maxHeight:) from the ScrollView                ║
// ║                                                                            ║
// ║ If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT     ║
// ║ ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment   ║
// ║ is removed is major major major.                                           ║
// ╙────────────────────────────────────────────────────────────────────────────╜
// Phase 5: DesignToken colour sweep
// Phase 7: meta badge backgrounds -> .glassCard(cornerRadius: RBRadius.small).
/// Shows the raw log text for a single `GitHubStep`.
///
/// Placed by `AppDelegate.navigate()` (rootView swap). Fits the fixed popover frame;
/// `ScrollView` absorbs overflow. Fetches log on `onAppear` via a background task;
/// cancelled automatically on `onDisappear` to avoid wasted work on fast back-navigation.
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
    /// Bound to the `AppState`-owned `LogFetcher` so the ZIP cache survives
    /// across step taps. Threading it down via `@Binding` keeps the ZIP cache
    /// alive for the lifetime of the panel session; the snapshot/writeback
    /// pattern in `StepLogContentView.loadLog()` propagates updates back.
    @Binding var logFetcher: LogFetcher

    /// Creates a `StepLogView` for the given job step.
    /// - Parameters:
    ///   - job: The job that owns the step.
    ///   - step: The step whose log will be fetched and displayed.
    ///   - onBack: Called when the user taps the back button.
    ///   - onLogLoaded: Optional callback fired on the main thread once the log fetch completes.
    ///   - scopeStore: Scope store used for API scope resolution. Defaults to `ScopeStore.shared`.
    init(
        job: ActiveJob,
        step: GitHubStep,
        logFetcher: Binding<LogFetcher> = .constant(LogFetcher()), // preview/test only — production callers must pass AppState's @Binding; .constant writes are silently dropped
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
            // ⚠️ REQUIRED -- caps preferredContentSize.height. Prevents panel growing off-screen.
            // ❌ NEVER remove this modifier.
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        // ════════════════════════════════════════════════════════════════════════
        // ⚠️ idealWidth: 480 hints the initial panel width before KVO fires.
        // ❌ NEVER use .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ❌ NEVER omit idealWidth: 480
        // ❌ NEVER add .frame(height:) or .fixedSize() here
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment
        // is removed is major major major.
        // ════════════════════════════════════════════════════════════════════════
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
    }
}
