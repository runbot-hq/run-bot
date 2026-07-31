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
    var scopeStore: any ScopeStoreProtocol = ScopeStore.shared
    /// `nil` = not yet fetched; `""` = fetch returned empty; non-empty = log text.
    /// Kept for `LogCopyButton` compatibility — mirrors `logResult.text`.
    @State private var logText: String?
    /// The typed result of the last step log fetch. Drives the scroll-view rendering.
    @State private var logResult: StepLogResult?
    /// `true` while the background fetch is in-flight.
    @State private var isLoading = true
    /// Handle for the in-flight log fetch task; cancelled in `onDisappear` and at the
    /// top of `loadLog()` to prevent races if `onAppear` fires more than once.
    @State private var loadTask: Task<Void, Never>?
    /// Bound to the `AppState`-owned `LogFetcher` so the ZIP cache survives
    /// across step taps. `@State` would be discarded on every `.id(navState)`
    /// remount in `RootPanelView` (SwiftUI tears down the full state tree when
    /// the identity key changes, which happens on every step tap). By owning
    /// `LogFetcher` in `AppState` and threading it down via `@Binding`, the
    /// ZIP cache persists for the lifetime of the panel session: the second
    /// step tap in the same run hits the cache and skips the network call.
    /// The snapshot/writeback pattern in `loadLog()` propagates cache updates
    /// back to `AppState` through this binding on the MainActor after each fetch.
    @Binding var logFetcher: LogFetcher

    // MARK: - Formatters (static to avoid re-allocation per render)
    /// `HH:mm:ss` formatter used for start/end time labels in the meta row.
    private static let timeFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    /// `yyyy-MM-dd` formatter used for the date label in the meta row.
    private static let dateFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    /// ISO 8601 formatter used to parse `step.startedAt` and `step.completedAt` strings.
    /// Cached as a static let because ISO8601DateFormatter is not cheap to allocate.
    private static let iso8601Fmt = ISO8601DateFormatter()

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
        logFetcher: Binding<LogFetcher> = .constant(LogFetcher()),
        onBack: @escaping () -> Void,
        onLogLoaded: (() -> Void)? = nil,
        scopeStore: any ScopeStoreProtocol = ScopeStore.shared
    ) {
        self.job = job
        self.step = step
        self._logFetcher = logFetcher
        self.onBack = onBack
        self.onLogLoaded = onLogLoaded
        self.scopeStore = scopeStore
    }

    /// Root body -- top bar, step name, meta rows, and the capped log scroll view.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                if let urlString = job.htmlUrl, let url = URL(string: urlString) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "safari").font(.caption)
                            Text("GitHub").font(.caption)
                        }
                        .foregroundColor(Color.rbTextSecondary)
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("Open job on GitHub")
                }
                LogCopyButton(
                    fetch: { completion in
                        let text = logText
                        completion(text)
                    },
                    isDisabled: logText == nil || logText?.isEmpty == true
                )
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Text(step.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, RBSpacing.md)
                .padding(.bottom, 5)

            HStack(spacing: 6) {
                Image(systemName: "briefcase").font(.system(size: 10)).foregroundColor(Color.rbTextSecondary)
                Text(job.name).font(.caption).foregroundColor(Color.rbTextSecondary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Spacer()
                Text("step #\(step.number)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.rbTextSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .glassCard(cornerRadius: RBRadius.small)
                    .fixedSize()
            }
            .padding(.horizontal, RBSpacing.md).padding(.bottom, 3)

            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 10)).foregroundColor(Color.rbTextSecondary)
                Text(repoSlug).font(.caption).foregroundColor(Color.rbTextSecondary).lineLimit(1).fixedSize()
                Spacer()
                Text("job #\(job.id)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.rbTextSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .glassCard(cornerRadius: RBRadius.small)
                    .fixedSize()
            }
            .padding(.horizontal, RBSpacing.md).padding(.bottom, 3)

            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 10)).foregroundColor(Color.rbTextSecondary)
                Text(startLabel)
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Color.rbTextSecondary).fixedSize()
                Text("→").font(.system(size: 10)).foregroundColor(Color.rbTextSecondary)
                Text(endLabel)
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Color.rbTextSecondary).fixedSize()
                Text("·").font(.system(size: 10)).foregroundColor(Color.rbTextSecondary)
                Text(step.elapsed)
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Color.rbTextSecondary).fixedSize()
                Text("·").font(.system(size: 10, design: .monospaced)).foregroundColor(Color.rbTextSecondary)
                Text(dateLabel)
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Color.rbTextSecondary).fixedSize()
                Spacer()
                Text(stepStatusLabel)
                    .font(.system(size: 10, weight: .medium)).foregroundColor(stepStatusColor).fixedSize()
            }
            .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)

            Divider()

            // ⚠️ .frame(maxHeight:) cap is REQUIRED on this ScrollView (ref #370).
            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small).padding(.vertical, 20)
                        Spacer()
                    }
                } else {
                    switch logResult {
                    case .slice(let content):
                        Text(content)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color.rbTextPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
                    case .flatBlobFallback(let content):
                        VStack(alignment: .leading, spacing: 4) {
                            Text("⚠️ Per-step logs unavailable for this run — showing full job log")
                                .font(.caption).foregroundColor(Color.rbWarning)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, RBSpacing.md).padding(.top, 6)
                            Divider().padding(.horizontal, RBSpacing.md)
                            Text(content)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color.rbTextPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
                        }
                    case .syntheticEmpty(let name):
                        Text("No output recorded for \"\(name)\"")
                            .font(.caption).foregroundColor(Color.rbTextSecondary)
                            .padding(.horizontal, RBSpacing.md).padding(.vertical, 8)
                    case .fetchFailed:
                        Text("Failed to fetch log")
                            .font(.caption).foregroundColor(Color.rbDanger)
                            .padding(.horizontal, RBSpacing.md).padding(.vertical, 8)
                    case nil:
                        Text("Log not available")
                            .font(.caption).foregroundColor(Color.rbTextSecondary)
                            .padding(.horizontal, RBSpacing.md).padding(.vertical, 8)
                    }
                }
            }
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
        .onAppear { loadLog() }
        .onDisappear { loadTask?.cancel() }
    }

    // MARK: - Log loading
    /// Kicks off a background fetch of the step log and publishes the result to `logText`.
    ///
    /// Cancels any in-flight `loadTask` before spawning a new one — prevents a stale
    /// task from writing to `@State` if `onAppear` fires more than once (e.g. view
    /// re-parenting or navigation stack identity change).
    ///
    /// Uses `repoScopeForFetch` (derived from `job.htmlUrl`) as the primary scope.
    /// Falls back to the first `owner/repo`-style entry in all entries (including
    /// disabled ones) when `htmlUrl` is absent or malformed — deliberate policy
    /// exception from the "active only" principle established by #1515. The saved
    /// repo is always preferred over an unrelated active repo for log fetching (#1106 intent).
    ///
    /// ## Known cancellation limitation
    ///
    /// `loadTask?.cancel()` signals cooperative cancellation but does NOT abort the
    /// underlying network I/O inside `fetchStepLog`. Because `fetchStepLog` does not
    /// itself check `Task.isCancelled` at suspension points, the network call runs to
    /// completion regardless. The `guard !Task.isCancelled` below therefore does NOT
    /// prevent a previous task's result from being committed if the task was cancelled
    /// and then re-checked before Swift's cooperative cancellation machinery fires —
    /// it merely reduces the window, not closes it.
    ///
    /// Concretely: on fast back → forward navigation, `loadLog()` cancels the old handle
    /// and stores a new one, but the old `Task` is still alive. Its `Task.isCancelled`
    /// may still be `false` at the `guard` site, so it can write stale log content.
    ///
    /// TODO: make `fetchStepLog` cancellation-cooperative (check `Task.isCancelled` after
    /// each URLSession suspension point) to fully close this race.
    private func loadLog() {
        loadTask?.cancel() // Signals cancellation; does NOT abort in-flight network I/O.
        isLoading = true
        let jobID = job.id
        let runID = job.runID
        let startedAt = job.startedAt
        let jobName = job.name
        let capturedStep = step
        let scope: String = {
            let primary = repoScopeForFetch
            if !primary.isEmpty { return primary }
            // ✅ Use injected scopeStore (not singleton). Falls back to any entry (including
            // disabled) per #1515 policy exception — saved repo preferred over unrelated active repo.
            return scopeStore.entries.first(where: { $0.scope.contains("/") })?.scope ?? ""
        }()
        // Capture a copy of the fetcher so the mutating fetchStepLog call (which updates
        // zipCache) is legal inside the Task. After the call we write the updated copy
        // back to `logFetcher` on the MainActor so the cache is preserved for the next tap.
        let fetcherSnapshot = logFetcher
        loadTask = Task {
            // Do NOT use `defer` for `isLoading = false`: a `defer` fires even on the
            // early-cancel `guard` returns below, which would clear the spinner while a
            // *new* task is still in flight, briefly flashing "Log not available" to the
            // user. Instead, clear `isLoading` only on the two paths that actually settle
            // the view: the cancellation bailout after the fetch (where we do nothing and
            // the new task owns loading state), and the successful write-back path.
            guard !Task.isCancelled else { return }
            var localFetcher = fetcherSnapshot
            let result = await localFetcher.fetchStepLog(
                runID: runID,
                startedAt: startedAt,
                jobID: jobID,
                jobName: jobName,
                step: capturedStep,
                scope: scope
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                logFetcher = localFetcher  // persist updated zipCache back to view state
                logResult = result
                logText = result.text ?? ""
                isLoading = false
                onLogLoaded?()
            }
        }
    }

    // MARK: - Derived repo scope
    /// Derives a `owner/repo` scope string from `job.htmlUrl` for use in `fetchStepLog`.
    ///
    /// Parses the URL path: `https://github.com/{owner}/{repo}/runs/{id}` → `"{owner}/{repo}"`.
    /// Returns an empty string when `htmlUrl` is absent or the path cannot be parsed.
    private var repoScopeForFetch: String {
        guard let urlString = job.htmlUrl,
              let url = URL(string: urlString),
              url.host == "github.com" else { return "" }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return "" }
        return "\(parts[0])/\(parts[1])"
    }

    // MARK: - Meta row computed properties

    /// `owner/repo` slug derived from `job.htmlUrl` for the meta row.
    private var repoSlug: String { repoScopeForFetch.isEmpty ? "—" : repoScopeForFetch }

    /// Formatted start time string, or `"—"` when the step has not yet started.
    private var startLabel: String {
        guard let startedAtString = step.startedAt,
              let date = Self.iso8601Fmt.date(from: startedAtString) else { return "—" }
        return Self.timeFmt.string(from: date)
    }

    /// Formatted end time string, or a status string when the step is still running.
    private var endLabel: String {
        guard let completedAtString = step.completedAt,
              let dateValue = Self.iso8601Fmt.date(from: completedAtString) else {
            return step.status == "in_progress" ? "running…" : "—"
        }
        return Self.timeFmt.string(from: dateValue)
    }

    /// Formatted date string derived from `step.startedAt`, or `"—"`.
    private var dateLabel: String {
        guard let startedAtString = step.startedAt,
              let date = Self.iso8601Fmt.date(from: startedAtString) else { return "—" }
        return Self.dateFmt.string(from: date)
    }

    /// Human-readable label derived from the step's conclusion and status.
    ///
    /// Maps `GitHubStep.conclusion` (raw `String?`) through `JobConclusion` for
    /// display, falling back to a running/queued label when conclusion is absent.
    private var stepStatusLabel: String {
        guard let raw = step.conclusion else {
            return step.status == "in_progress" ? "▶ running" : "· queued"
        }
        switch JobConclusion(rawString: raw) {
        case .success:                          return "✓ success"
        case .failure:                          return "✗ failure"
        case .cancelled:                        return "⊘ cancelled"
        case .neutral:                          return "· neutral"
        case .skipped:                          return "⊘ skipped"
        case .timedOut:                         return "✗ timed out"
        case .actionRequired:                   return "! action required"
        case .stale:                            return "· stale"
        case .startupFailure:                   return "✗ startup failure"
        case .unknown(let raw):                 return "· \(raw)"
        }
    }

    /// Foreground colour for the step status label.
    ///
    /// Maps `GitHubStep.conclusion` (raw `String?`) through `JobConclusion` for
    /// colour selection, falling back to warning/secondary colours when absent.
    private var stepStatusColor: Color {
        guard let raw = step.conclusion else {
            return step.status == "in_progress" ? Color.rbWarning : Color.rbTextSecondary
        }
        switch JobConclusion(rawString: raw) {
        case .success:                          return Color.rbSuccess
        case .failure, .timedOut,
             .actionRequired, .startupFailure: return Color.rbDanger
        case .skipped, .cancelled, .neutral, .stale,
             .unknown:                         return Color.rbTextSecondary
        }
    }
}
