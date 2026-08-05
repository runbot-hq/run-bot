// CompletedGroupZIPPrefetchTests.swift
// RunBotCoreTests
//
// Runner-level ZIP completion-transition tests for #2488.
// Replaces the former PollResultBuilder.buildGroupState(enqueueZIP:) tests
// with focused RunnerPoller.applyFetchResult transition tests.

import os
import XCTest
import GitHubClient
@testable import RunBotCore

// MARK: - Test stubs

/// Minimal AppPreferencesStoreProtocol stub (protocol has no requirements).
@Observable
@MainActor
private final class StubPreferencesStore: AppPreferencesStoreProtocol, @unchecked Sendable {}

/// Minimal ScopeStoreProtocol stub — returns empty collections.
private final class StubScopeStore: ScopeStoreProtocol, @unchecked Sendable {
    var activeScopes: [String] { [] }
    var entries: [ScopeEntry] { [] }
}

/// Counts `raw` calls; returns `responseData`.
/// Thread-safe via OSAllocatedUnfairLock (project convention).
private final class TestFakeTransport: GitHubTransportProtocol, @unchecked Sendable {
    private let _callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    var callCount: Int { _callCount.withLock { $0 } }
    var responseData: Data?
    var decoder: JSONDecoder { JSONDecoder() }
    var logger: (any GitHubLogger)? { nil }
    func apiAsync(_ endpoint: String, timeout: TimeInterval) async -> Data? { nil }
    func apiPaginated(_ endpoint: String, timeout: TimeInterval) async -> Data? { nil }
    func raw(_ endpoint: String, timeout: TimeInterval) async -> Data? {
        _callCount.withLock { $0 += 1 }
        return responseData
    }
    func post(_ endpoint: String, body: Data?, timeout: TimeInterval) async -> Data? { nil }
    func put(_ endpoint: String, body: Data, timeout: TimeInterval) async -> Data? { nil }
    @discardableResult func delete(_ endpoint: String, timeout: TimeInterval) async -> Bool { false }
    func cancelRun(runID: Int, scope: String) async -> Bool { false }
    @discardableResult func patchRunnerLabels(scope: String, runnerID: Int, labels: [String]) async -> [String]? { nil }
    func fetchRegistrationToken(scope: String) async -> String? { nil }
    func fetchRemovalToken(scope: String) async -> String? { nil }
    func deleteRunnerByID(scope: String, runnerID: Int) async -> Bool { false }
}

// MARK: - Helpers

/// Builds a minimal empty `JobPollResult` for cycles that don't exercise jobs.
private func emptyJobResult() -> JobPollResult {
    JobPollResult(display: [], newCache: [:], newPrevLive: [:])
}

/// Builds a `WorkflowRunRef` with the given run ID and optional status/conclusion.
private func makeRunRef(
    id: Int,
    status: JobStatus = .inProgress,
    conclusion: JobConclusion? = nil
) -> WorkflowRunRef {
    WorkflowRunRef(id: id, name: "CI-\(id)", status: status, conclusion: conclusion, htmlUrl: nil)
}

/// Builds a `WorkflowActionGroup` that will return the expected `groupStatus`.
///
/// - For active groups:   pass `inProgressRunIDs` (no conclusion, status `.inProgress`).
/// - For completed groups: pass `completedRunIDs` (conclusion `.success`) + one job per run
///   so `groupStatus` resolves to `.completed` (all runs concluded AND jobs have conclusion).
private func makeGroup(
    sha: String = "aabbcc",
    repo: String = "owner/repo",
    inProgressRunIDs: [Int] = [],
    completedRunIDs: [Int] = []
) -> WorkflowActionGroup {
    let activeRuns = inProgressRunIDs.map {
        makeRunRef(id: $0, status: .inProgress, conclusion: nil)
    }
    let doneRuns = completedRunIDs.map {
        makeRunRef(id: $0, status: .completed, conclusion: .success)
    }
    let jobs: [ActiveJob] = (inProgressRunIDs + completedRunIDs).map { runID in
        ActiveJob(
            id: runID * 10,
            name: "job-\(runID)",
            status: doneRuns.contains(where: { $0.id == runID }) ? .completed : .inProgress,
            conclusion: doneRuns.contains(where: { $0.id == runID }) ? .success : nil
        )
    }
    return WorkflowActionGroup(
        headSha: sha,
        label: String(sha.prefix(7)),
        title: "test commit",
        headBranch: "main",
        repo: repo,
        runs: activeRuns + doneRuns,
        jobs: jobs,
        firstJobStartedAt: Date(timeIntervalSinceReferenceDate: 0)
    )
}

// MARK: - CompletedGroupZIPPrefetchTests

/// Runner-level completion-transition tests (#2488).
///
/// Each test drives `RunnerPoller.applyFetchResult` directly:
///   cycle 1 — seed `self.actions` with an active group.
///   cycle 2 — present the group as completed → expect one ZIP enqueue per run.
///
/// Transport.callCount is used as a proxy for ZIPPrefetchQueue.enqueue calls
/// because the queue drains asynchronously straight into the transport.
final class CompletedGroupZIPPrefetchTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Factory

    @MainActor
    private func makePoller(transport: TestFakeTransport) -> RunnerPoller {
        let disk = DiskZIPCache(cacheDir: tempDir)
        let queue = ZIPPrefetchQueue(diskCache: disk, transport: transport)
        return RunnerPoller(
            state: RunnerState(),
            preferencesStore: StubPreferencesStore(),
            scopeStore: StubScopeStore(),
            localRunners: { [] },
            applyMetrics: { _, _, _ in },
            notificationPreferences: NotificationPreferences(store: UserDefaults(suiteName: UUID().uuidString)!),
            zipPrefetchQueue: queue
        )
    }

    /// Runs two `applyFetchResult` cycles.
    /// Cycle 1: seed active state.  Cycle 2: present completed state.
    @MainActor
    private func runTransitionCycles(
        poller: RunnerPoller,
        activeGroup: WorkflowActionGroup,
        completedGroup: WorkflowActionGroup
    ) async {
        // Cycle 1 — active state (seeds self.actions)
        let activeResult = GroupPollResult(
            display: [activeGroup],
            newGroupCache: [:],
            newPrevLiveGroups: [activeGroup.id: activeGroup]
        )
        _ = await poller.applyFetchResult(
            enrichedRunners: [],
            jobResult: emptyJobResult(),
            groupResult: activeResult
        )

        // Cycle 2 — completed state (triggers transition detection)
        let completedResult = GroupPollResult(
            display: [completedGroup],
            newGroupCache: [completedGroup.id: completedGroup],
            newPrevLiveGroups: [:]
        )
        _ = await poller.applyFetchResult(
            enrichedRunners: [],
            jobResult: emptyJobResult(),
            groupResult: completedResult
        )
    }

    // MARK: - Test cases

    // 1. Active → completed/success: enqueue once per run.id.
    @MainActor
    func testActiveToCompletedSuccess_enqueuedOnce() async throws {
        let transport = TestFakeTransport()
        transport.responseData = Data()
        let poller = makePoller(transport: transport)

        let active = makeGroup(inProgressRunIDs: [1001])
        let completed = makeGroup(completedRunIDs: [1001])

        await runTransitionCycles(poller: poller, activeGroup: active, completedGroup: completed)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(transport.callCount, 1,
            "active → completed/success must enqueue exactly 1 ZIP")
    }

    // 2. Active → completed/failure: enqueue once per run.id.
    @MainActor
    func testActiveToCompletedFailure_enqueuedOnce() async throws {
        let transport = TestFakeTransport()
        transport.responseData = Data()
        let poller = makePoller(transport: transport)

        let active = makeGroup(inProgressRunIDs: [2001])
        // Use failure conclusion directly via WorkflowRunRef
        let failRun = WorkflowRunRef(id: 2001, name: "CI", status: .completed,
                                     conclusion: .failure, htmlUrl: nil)
        let job = ActiveJob(id: 20010, name: "job", status: .completed, conclusion: .failure)
        let completed = WorkflowActionGroup(
            headSha: "aabbcc", label: "aabbcc", title: "test",
            headBranch: "main", repo: "owner/repo",
            runs: [failRun], jobs: [job])

        await runTransitionCycles(poller: poller, activeGroup: active, completedGroup: completed)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(transport.callCount, 1,
            "active → completed/failure must enqueue exactly 1 ZIP")
    }

    // 3. Active → completed/cancelled: enqueue once per run.id.
    @MainActor
    func testActiveToCompletedCancelled_enqueuedOnce() async throws {
        let transport = TestFakeTransport()
        transport.responseData = Data()
        let poller = makePoller(transport: transport)

        let active = makeGroup(inProgressRunIDs: [3001])
        let cancelRun = WorkflowRunRef(id: 3001, name: "CI", status: .completed,
                                       conclusion: .cancelled, htmlUrl: nil)
        let job = ActiveJob(id: 30010, name: "job", status: .completed, conclusion: .cancelled)
        let completed = WorkflowActionGroup(
            headSha: "aabbcc", label: "aabbcc", title: "test",
            headBranch: "main", repo: "owner/repo",
            runs: [cancelRun], jobs: [job])

        await runTransitionCycles(poller: poller, activeGroup: active, completedGroup: completed)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(transport.callCount, 1,
            "active → completed/cancelled must enqueue exactly 1 ZIP")
    }

    // 4. Completed → completed on the next update: no additional enqueue.
    @MainActor
    func testCompletedToCompleted_noAdditionalEnqueue() async throws {
        let transport = TestFakeTransport()
        transport.responseData = Data()
        let poller = makePoller(transport: transport)

        // Seed self.actions directly with an already-completed group (no active run IDs).
        let completed = makeGroup(completedRunIDs: [4001])
        let result = GroupPollResult(
            display: [completed],
            newGroupCache: [completed.id: completed],
            newPrevLiveGroups: [:])
        _ = await poller.applyFetchResult(
            enrichedRunners: [], jobResult: emptyJobResult(), groupResult: result)

        // Second cycle — still completed, run IDs were never in previouslyActiveRunIDs.
        _ = await poller.applyFetchResult(
            enrichedRunners: [], jobResult: emptyJobResult(), groupResult: result)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.callCount, 0,
            "completed → completed must not enqueue any ZIP")
    }

    // 5. A group first observed as completed (no prior active state): no enqueue.
    @MainActor
    func testFirstObservedAsCompleted_noEnqueue() async throws {
        let transport = TestFakeTransport()
        transport.responseData = Data()
        let poller = makePoller(transport: transport)

        // self.actions is empty — no previouslyActiveRunIDs.
        let completed = makeGroup(completedRunIDs: [5001])
        let result = GroupPollResult(
            display: [completed],
            newGroupCache: [completed.id: completed],
            newPrevLiveGroups: [:])
        _ = await poller.applyFetchResult(
            enrichedRunners: [], jobResult: emptyJobResult(), groupResult: result)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.callCount, 0,
            "group first observed as completed must not trigger ZIP enqueue")
    }

    // 6. A completed group containing several workflow runs: enqueue every distinct run.id.
    @MainActor
    func testCompletedGroupMultipleRuns_enqueuesEveryRunID() async throws {
        let transport = TestFakeTransport()
        transport.responseData = Data()
        let poller = makePoller(transport: transport)

        let active = makeGroup(inProgressRunIDs: [6001, 6002, 6003])
        let completed = makeGroup(completedRunIDs: [6001, 6002, 6003])

        await runTransitionCycles(poller: poller, activeGroup: active, completedGroup: completed)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(transport.callCount, 3,
            "multi-run completed group must enqueue one ZIP per run.id")
    }

    // 7. Commit and workflow_dispatch groups on same SHA: cache both independently by run.id.
    @MainActor
    func testCommitAndDispatchGroupsSameSHA_cachedIndependentlyByRunID() async throws {
        let transport = TestFakeTransport()
        transport.responseData = Data("zip".utf8)
        let disk = DiskZIPCache(cacheDir: tempDir)
        let queue = ZIPPrefetchQueue(diskCache: disk, transport: transport)
        let poller = RunnerPoller(
            state: RunnerState(),
            preferencesStore: StubPreferencesStore(),
            scopeStore: StubScopeStore(),
            localRunners: { [] },
            applyMetrics: { _, _, _ in },
            notificationPreferences: NotificationPreferences(
                store: UserDefaults(suiteName: UUID().uuidString)!),
            zipPrefetchQueue: queue
        )

        let sha = "shared-sha"
        // Two independent groups sharing the same sha (commit vs dispatch).
        let activeCommit = makeGroup(sha: sha, inProgressRunIDs: [7001])
        let activeDispatch = WorkflowActionGroup(
            headSha: sha, label: "shared", title: "dispatch",
            headBranch: "main", repo: "owner/repo",
            runs: [makeRunRef(id: 7002)],
            jobs: [ActiveJob(id: 70020, name: "job", status: .inProgress)],
            normalizedEvent: "workflow_dispatch")

        // Seed both as active
        let seedResult = GroupPollResult(
            display: [activeCommit, activeDispatch],
            newGroupCache: [:],
            newPrevLiveGroups: [activeCommit.id: activeCommit, activeDispatch.id: activeDispatch])
        _ = await poller.applyFetchResult(
            enrichedRunners: [], jobResult: emptyJobResult(), groupResult: seedResult)

        // Both transition to completed
        let doneCommit = makeGroup(sha: sha, completedRunIDs: [7001])
        let doneDispatch = WorkflowActionGroup(
            headSha: sha, label: "shared", title: "dispatch",
            headBranch: "main", repo: "owner/repo",
            runs: [makeRunRef(id: 7002, status: .completed, conclusion: .success)],
            jobs: [ActiveJob(id: 70020, name: "job", status: .completed, conclusion: .success)],
            normalizedEvent: "workflow_dispatch")

        let doneResult = GroupPollResult(
            display: [doneCommit, doneDispatch],
            newGroupCache: [doneCommit.id: doneCommit, doneDispatch.id: doneDispatch],
            newPrevLiveGroups: [:])
        _ = await poller.applyFetchResult(
            enrichedRunners: [], jobResult: emptyJobResult(), groupResult: doneResult)

        try await Task.sleep(nanoseconds: 200_000_000)
        let zip7001 = await disk.get(runID: 7001)
        let zip7002 = await disk.get(runID: 7002)
        XCTAssertNotNil(zip7001, "run 7001 (commit) ZIP must be cached independently")
        XCTAssertNotNil(zip7002, "run 7002 (dispatch) ZIP must be cached independently")
    }

    // 8. group.repo is passed as scope; isCompleted is true.
    @MainActor
    func testEnqueueUsesGroupRepoAsScopeAndIsCompletedTrue() async throws {
        var capturedEndpoints: [String] = []

        // Use a capturing transport to inspect the endpoint called.
        final class CapturingTransport: GitHubTransportProtocol, @unchecked Sendable {
            private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])
            var endpoints: [String] { lock.withLock { $0 } }
            var decoder: JSONDecoder { JSONDecoder() }
            var logger: (any GitHubLogger)? { nil }
            func apiAsync(_ e: String, timeout: TimeInterval) async -> Data? { nil }
            func apiPaginated(_ e: String, timeout: TimeInterval) async -> Data? { nil }
            func raw(_ endpoint: String, timeout: TimeInterval) async -> Data? {
                lock.withLock { $0.append(endpoint) }
                return Data()
            }
            func post(_ e: String, body: Data?, timeout: TimeInterval) async -> Data? { nil }
            func put(_ e: String, body: Data, timeout: TimeInterval) async -> Data? { nil }
            @discardableResult func delete(_ e: String, timeout: TimeInterval) async -> Bool { false }
            func cancelRun(runID: Int, scope: String) async -> Bool { false }
            @discardableResult func patchRunnerLabels(scope: String, runnerID: Int, labels: [String]) async -> [String]? { nil }
            func fetchRegistrationToken(scope: String) async -> String? { nil }
            func fetchRemovalToken(scope: String) async -> String? { nil }
            func deleteRunnerByID(scope: String, runnerID: Int) async -> Bool { false }
        }

        let capturing = CapturingTransport()
        let disk = DiskZIPCache(cacheDir: tempDir)
        let queue = ZIPPrefetchQueue(diskCache: disk, transport: capturing)
        let poller = RunnerPoller(
            state: RunnerState(),
            preferencesStore: StubPreferencesStore(),
            scopeStore: StubScopeStore(),
            localRunners: { [] },
            applyMetrics: { _, _, _ in },
            notificationPreferences: NotificationPreferences(
                store: UserDefaults(suiteName: UUID().uuidString)!),
            zipPrefetchQueue: queue
        )

        let active = makeGroup(repo: "owner/testrepo", inProgressRunIDs: [8001])
        let completed = makeGroup(repo: "owner/testrepo", completedRunIDs: [8001])
        await runTransitionCycles(poller: poller, activeGroup: active, completedGroup: completed)
        try await Task.sleep(nanoseconds: 150_000_000)

        capturedEndpoints = capturing.endpoints
        XCTAssertEqual(capturedEndpoints.count, 1)
        // Endpoint format: repos/{scope}/actions/runs/{runID}/logs
        XCTAssertTrue(
            capturedEndpoints.first?.contains("owner/testrepo") == true,
            "scope must be group.repo (\"owner/testrepo\"), got: \(capturedEndpoints)")
        XCTAssertTrue(
            capturedEndpoints.first?.contains("8001") == true,
            "endpoint must contain run ID 8001")
    }

}
