// StepLogContentView.swift
// RunBot
import AppKit
import GitHubClient
import MarkdownKit
import OSLog
import RunBotCore
import SwiftUI

/// OSLog logger for markdown render toggle events.
private let markdownRenderLogger = Logger(
    subsystem: "com.runbot-hq.RunBot",
    category: "MarkdownRender"
)

/// Reusable step-log content view — fetch lifecycle, toolbar, metadata, and log body.
///
/// Extracted from `StepLogView` so it can be embedded in both the panel-based
/// popover UI and the windowed `MigrationStepLogView` without duplication.
///
/// Callers are responsible for the `maxHeight` cap on this view (ref #370).
@MainActor
struct StepLogContentView: View {
    /// The job that owns this step.
    let job: ActiveJob
    /// The step whose log will be displayed.
    let step: GitHubStep
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
    @State private var logText: String?
    /// The typed result of the last step log fetch. Drives the scroll-view rendering.
    @State private var logResult: StepLogResult?
    /// Parsed log lines produced by `parseLogLines` after a successful fetch.
    /// Empty until `loadLog` completes. Drives the `LazyVStack` in the scroll view.
    @State private var parsedLines: [LogLine] = []
    /// IDs of `groupHeader` lines whose child rows are currently hidden.
    /// All groups start collapsed (matching GitHub.com behaviour) and are toggled by
    /// tapping the group header row.
    @State private var collapsedGroups: Set<Int> = []
    /// `true` while the background fetch is in-flight.
    @State private var isLoading = true
    /// Handle for the in-flight log fetch task; cancelled in `onDisappear` and at the
    /// top of `loadLog()` to prevent races if `onAppear` fires more than once.
    @State private var loadTask: Task<Void, Never>?
    /// Monotonically incremented each time `loadLog()` starts a new fetch.
    /// Captured into the task and checked inside `MainActor.run` so a superseded
    /// (cancelled) task can never commit stale state even when `Task.isCancelled`
    /// hasn't propagated yet.
    @State private var loadGeneration: Int = 0
    /// Whether markdown rendering is active for this log.
    ///
    /// `loadLog()` may re-run during the lifetime of this view (for example on a
    /// live-step refresh), so auto-enable must not blindly overwrite a user's
    /// manual toggle-off after the first interaction.
    @State private var isMarkdownMode: Bool = false
    /// Guards auto-enable so it fires at most once per log identity.
    /// `isMarkdownMode` alone can't distinguish "never set" from "user toggled off"; once
    /// the user explicitly toggles, this flag prevents `loadLog()` write-backs from
    /// overriding their choice during live refreshes.
    @State private var hasToggledMarkdown: Bool = false
    /// `isMarkdownMode` alone can't distinguish "never set" from "user toggled off" —
    /// Bound to the `AppState`-owned `LogFetcher` so the ZIP cache survives
    /// across step taps. `@State` would be discarded on every `.id(navState)`
    /// remount in `RootPanelView` (SwiftUI tears down the full state tree when
    /// the identity key changes, which happens on every step tap). By owning
    /// `LogFetcher` in `AppState` and threading it down via `@Binding`, the
    /// ZIP cache persists for the lifetime of the panel session: the second
    /// step tap in the same run hits the cache and skips the network call.
    /// The snapshot/writeback pattern in `loadLog()` propagates cache updates
    /// back to `AppState` through this binding on the MainActor after each fetch.
    /// Bound to the `AppState`-owned `LogFetcher` so the ZIP cache survives
    /// across step taps.
    @Binding var logFetcher: LogFetcher

    init(
        job: ActiveJob,
        step: GitHubStep,
        logFetcher: Binding<LogFetcher>,
        onLogLoaded: (() -> Void)? = nil,
        scopeStore: (any ScopeStoreProtocol)? = nil
    ) {
        self.job = job
        self.step = step
        self._logFetcher = logFetcher
        self.onLogLoaded = onLogLoaded
        self.scopeStore = scopeStore ?? ScopeStore.shared
    }

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
    /// ISO 8601 formatters used to parse `step.startedAt` and `step.completedAt` strings.
    /// Cached as static lets because ISO8601DateFormatter is not cheap to allocate.
    ///
    /// GitHub commonly returns timestamps without fractional seconds (e.g. `"2026-08-08T16:07:14Z"`).
    /// Try fractional first (catches `.000Z` responses), then fall back to standard.
    private static let iso8601FmtFractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()
    /// Standard ISO-8601 formatter (no fractional seconds). Used as fallback by `parseDate`.
    private static let iso8601Fmt = ISO8601DateFormatter()

    /// Parses an ISO-8601 timestamp string, trying fractional-seconds format first
    /// (`"2026-08-08T16:07:14.000Z"`), then falling back to standard format
    /// (`"2026-08-08T16:07:14Z"`). Returns `nil` only when both parsers fail.
    private static func parseDate(_ raw: String) -> Date? {
        iso8601FmtFractional.date(from: raw) ?? iso8601Fmt.date(from: raw)
    }

    /// Root body -- top bar, step name, meta rows, and the capped log scroll view.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    hasToggledMarkdown = true
                    isMarkdownMode.toggle()
                    markdownRenderLogger.notice(
                        "toggle userToggled=true isMarkdownMode=\(isMarkdownMode, privacy: .public)"
                    )
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isMarkdownMode ? "doc.richtext" : "doc.plaintext")
                            .font(.caption)
                        Text("MD").font(.caption)
                    }
                    .foregroundColor(isMarkdownMode ? Color.rbAccent : Color.rbTextSecondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .help(isMarkdownMode ? "Showing markdown — click for raw" : "Show as markdown")
                .padding(.horizontal, 5).padding(.vertical, 2)
                .glassCard(cornerRadius: RBRadius.small)
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
                    CopyLinkButton(url: urlString)
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
                        // content is String — StepLogResult.slice carries `content: String` (see LogFetcher.swift).
                        if isMarkdownMode {
                            MarkdownLogView(text: content)
                        } else {
                            logBodyView
                        }
                    case .flatBlobFallback(let content):
                        VStack(alignment: .leading, spacing: 4) {
                            Text("⚠️ Per-step logs unavailable for this run — showing full job log")
                                .font(.caption).foregroundColor(Color.rbWarning)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, RBSpacing.md).padding(.top, 6)
                            Divider().padding(.horizontal, RBSpacing.md)
                            if isMarkdownMode {
                                MarkdownLogView(text: content)
                            } else {
                                logBodyView
                            }
                        }
                    case .syntheticEmpty(let name, let reason):
                        VStack(alignment: .leading, spacing: 4) {
                            Text(logResult?.isSkipped == true ? "Step skipped" : "No output recorded for \"\(name)\"")
                                .font(.caption).foregroundColor(Color.rbTextSecondary)
                            Text(reason)
                                .font(.caption2).foregroundColor(Color.rbTextSecondary)
                        }
                            .padding(.horizontal, RBSpacing.md).padding(.vertical, 8)
                    case .fetchFailed(let reason):
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Failed to fetch log")
                                .font(.caption).foregroundColor(Color.rbDanger)
                            Text(reason)
                                .font(.caption2).foregroundColor(Color.rbTextSecondary)
                        }
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
        .onAppear {
            loadLog()
            #if DEBUG
            log(
                "[TimingTrace][step-log] "
                    + "step=\(step.number) "
                    + "rawStart=\(String(describing: step.startedAt)) "
                    + "rawEnd=\(String(describing: step.completedAt)) "
                    + "parsedStart=\(String(describing: step.startDate)) "
                    + "parsedEnd=\(String(describing: step.completedDate)) "
                    + "elapsed=\(step.elapsed)",
                category: .runner
            )
            #endif
        }
        .onDisappear {
            log("StepLogView.onDisappear › canceling gen=\(loadGeneration) job=\(job.id) step=\(step.number)", category: .services)
            loadTask?.cancel()
        }
    }

    /// Kicks off a background fetch of the step log and publishes the result to `logText`.
    ///
    /// Cancels any in-flight `loadTask` before spawning a new one — prevents a stale
    /// task from writing to `@State` if `onAppear` fires more than once (e.g. view
    /// re-parenting or navigation stack identity change).
    ///
    /// Uses `repoScopeForFetch` (derived from `job.htmlUrl`) as the primary scope.
    /// Falls back to the first `owner/repo`-style entry in all entries (including
    /// disabled ones) when `htmlUrl` is absent or malformed — deliberate policy
    /// exception from the “active only” principle established by #1515. The saved
    /// repo is always preferred over an unrelated active repo for log fetching (#1106 intent).
    ///
    /// ## Known cancellation limitation
    ///
    /// `loadTask?.cancel()` signals cooperative cancellation but does NOT abort
    /// in-flight network I/O. `fetchStepLog` now checks `Task.isCancelled` at key
    /// suspension points and logs each guard hit, but the URLSession transport call
    /// itself runs to completion. The `guard !Task.isCancelled` checks reduce the
    /// stale-write window but cannot close it entirely — on fast back → forward
    /// navigation, the old `Task.isCancelled` may still be `false` at the guard site.
    ///
    private func loadLog() {
        loadTask?.cancel() // Signals cancellation; does NOT abort in-flight network I/O.
        loadGeneration += 1
        isLoading = true
        // isMarkdownMode is intentionally NOT reset here: loadLog() can fire multiple
        // times per view lifetime (`.onAppear` re-fires on live-step refresh), and
        // resetting it would wipe the user's manual toggle-off. SwiftUI state teardown
        // on view identity change handles the fresh-start case. The auto-enable path
        // below (`if mdAuto { isMarkdownMode = true }`) only sets to true, never false,
        // so a user toggle-off is preserved across re-fetches.
        let jobID = job.id
        let runID = job.runID
        let startedAt = job.startedAt
        let runAttempt = job.runAttempt
        let cacheGroup = job.zipCacheGroupKey
        let jobName = job.name
        let capturedStep = step
        let scope: String = {
            let primary = repoScopeForFetch
            if !primary.isEmpty { return primary }
            // ✅ Use injected scopeStore (not singleton). Saved repo preferred over unrelated active repo (#1515).
            return scopeStore.entries.first(where: { $0.scope.contains("/") })?.scope ?? ""
        }()
        // Capture the fetcher copy so mutating fetchStepLog is legal inside the Task.
        let fetcherSnapshot = logFetcher
        let generation = loadGeneration
        log("loadLog › gen=\(loadGeneration) runID=\(runID) startedAt=\(startedAt ?? "nil") jobID=\(jobID) jobName='\(jobName)' step=\(step.number) scope='\(scope)'",
                category: .services)
        loadTask = Task { [loadStart = ContinuousClock.now] in
            // Do NOT use `defer` for `isLoading = false`: a `defer` fires even on early-cancel
            // guard returns, briefly flashing "Log not available" to the user while a new task
            // is still loading. Clear `isLoading` only on the two paths that settle the view.
            guard !Task.isCancelled else {
                log("loadLog.guard1 › generation=\(generation) cancelled before fetchStepLog — discarding", category: .services)
                return
            }
            let isStepCompleted = capturedStep.conclusion != nil
            let localFetcher = fetcherSnapshot
            let result = await localFetcher.fetchStepLog(
                runID: runID,
                startedAt: startedAt,
                runAttempt: runAttempt,
                cacheGroup: cacheGroup,
                jobID: jobID,
                jobName: jobName,
                step: capturedStep,
                scope: scope,
                isCompleted: isStepCompleted
            )
            guard !Task.isCancelled else {
                log("loadLog.guard2 › generation=\(generation) cancelled after fetchStepLog — discarding result", category: .services)
                return
            }
            let fetchDuration = loadStart.duration(to: .now)
            log("loadLog › fetchStepLog returned: \(result) elapsed=\(fetchDuration)", category: .services)
            // Offload parse to a detached task so the main thread stays free.
            // Markdown detection runs here too via a single detect(_:) call.
            let (parsed, defaultCollapsed, mdScore, mdAuto) = await Task.detached(priority: .userInitiated) {
                let lines = result.text.map { parseLogLines($0) } ?? []
                let collapsed = Set(lines.compactMap { line -> Int? in
                    if case .groupHeader(let id, _) = line { return id } else { return nil }
                })
                let text = result.text ?? ""
                let detected = MarkdownDetector.detect(text)
                return (lines, collapsed, detected.score, detected.looksLikeMarkdown)
            }.value
            guard !Task.isCancelled else {
                log("loadLog.guard3 › generation=\(generation) cancelled after parse — discarding parsed result", category: .services)
                return
            }
            let totalElapsed = loadStart.duration(to: .now)
            await MainActor.run { [generation] in
                // Generation check: if loadLog() has been called again since this task
                // was created, our result is stale — discard it silently.
                guard self.loadGeneration == generation else {
                    log("loadLog › generation MISMATCH gen=\(generation) current=\(self.loadGeneration) — discarding stale result", category: .services)
                    return
                }
                log("loadLog › writeback generation=\(generation) result=\(String(describing: result)) totalElapsed=\(totalElapsed)", category: .services)
                logFetcher = localFetcher  // persist updated zipCache back to view state
                logResult = result
                // logText nil/empty distinction: nil = not yet fetched, "" = fetch returned
                // no text. The ?? "" coalesces both, which is pre-existing behaviour; the
                // LogCopyButton disable check handles both correctly via isEmpty.
                logText = result.text ?? ""
                // Markdown state: boolean drives auto-enable.
                // Computed from a single detect(_:) call on the detached task above.
                // Respect the user's first manual toggle: once they explicitly choose
                // a mode, subsequent `loadLog()` writebacks must not force markdown
                // back on during refreshes or re-fetches.
                if mdAuto && !hasToggledMarkdown { isMarkdownMode = true }
                log("loadLog › markdown: score=\(mdScore) autoEnabled=\(mdAuto) userToggled=\(hasToggledMarkdown) finalMode=\(isMarkdownMode)", category: .services)
                applyGroupCollapseState(parsed: parsed, defaultCollapsed: defaultCollapsed)
                parsedLines = parsed
                isLoading = false
                onLogLoaded?()
            }
        }
    }

    // MARK: - Log helpers

    /// Merges `defaultCollapsed` with the user's previously expanded group titles
    /// and writes the result back into `collapsedGroups`.
    ///
    /// Group IDs are not stable across parse calls, so identity is keyed on title.
    /// Any title the user had manually expanded remains open; brand-new titles start
    /// collapsed by default.
    @MainActor
    private func applyGroupCollapseState(
        parsed: [LogLine],
        defaultCollapsed: Set<Int>
    ) {
        let previousTitles: [String: Int] = Dictionary(
            uniqueKeysWithValues: parsedLines.compactMap { line -> (String, Int)? in
                if case .groupHeader(let id, let title) = line { return (title, id) } else { return nil }
            }
        )
        let userExpandedTitles = Set(
            previousTitles.compactMap { title, id in collapsedGroups.contains(id) ? nil : title }
        )
        if collapsedGroups.isEmpty {
            collapsedGroups = defaultCollapsed
        } else {
            collapsedGroups = defaultCollapsed
            for line in parsed {
                if case .groupHeader(let id, let title) = line, userExpandedTitles.contains(title) {
                    collapsedGroups.remove(id)
                }
            }
        }
    }

    // MARK: - Log body

    /// The `LazyVStack` rendering of `parsedLines`.
    ///
    /// Shared by both the `.slice` and `.flatBlobFallback` cases so the group/annotation
    /// rendering is identical regardless of which log source was used.
    /// `LazyVStack` is required (not `VStack`) — logs can be thousands of lines.
    @ViewBuilder
    private var logBodyView: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(parsedLines) { line in
                switch line {
                case .plain(_, let text):
                    LogPlainLine(text: text)
                case .groupHeader(let id, let title):
                    LogGroupHeader(
                        title: title,
                        isCollapsed: collapsedGroups.contains(id),
                        onToggle: {
                            if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
                        }
                    )
                case .groupedLine(_, let text, let groupID):
                    // NOTE: collapsed groupedLine rows are absent from the view tree entirely,
                    // so a copy-all selection on the ScrollView will silently omit their content.
                    // This matches GitHub.com behaviour (collapsed sections aren't copy-selectable)
                    // and is acceptable; a future improvement could use hidden() instead.
                    if !collapsedGroups.contains(groupID) {
                        LogPlainLine(text: text)
                            .padding(.leading, 12)
                    }
                case .annotation(_, let level, let text, let params, let groupID):
                    if !(groupID.map { collapsedGroups.contains($0) } ?? false) {
                        LogAnnotationLine(level: level, text: text, params: params)
                    }
                case .dimmed(_, let text, let groupID):
                    if !(groupID.map { collapsedGroups.contains($0) } ?? false) {
                        LogDimmedLine(text: text)
                    }
                case .section(_, let title, let groupID):
                    if !(groupID.map { collapsedGroups.contains($0) } ?? false) {
                        LogSectionHeader(title: title)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
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
        guard let raw = step.startedAt, let date = Self.parseDate(raw) else { return "—" }
        return Self.timeFmt.string(from: date)
    }

    /// Formatted end time string, or a status string when the step is still running.
    private var endLabel: String {
        guard let raw = step.completedAt, let date = Self.parseDate(raw) else {
            return step.status == "in_progress" ? "running…" : "—"
        }
        return Self.timeFmt.string(from: date)
    }

    /// Formatted date string derived from `step.startedAt`, or `"—"`.
    private var dateLabel: String {
        guard let raw = step.startedAt, let date = Self.parseDate(raw) else { return "—" }
        return Self.dateFmt.string(from: date)
    }
}
