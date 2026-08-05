// CompletedGroupZIPPrefetchTests.swift
// RunBotCoreTests

import XCTest
import GitHubClient
@testable import RunBotCore

// MARK: - TestFakeTransport

/// Counts calls and returns configurable data or nil (simulate 404).
/// Uses a distinct name to avoid redeclaration conflict with
/// `FakeTransport` in `ZIPPrefetchQueueTests`.
private final class TestFakeTransport: GitHubTransportProtocol, @unchecked Sendable {
    var callCount = 0
    var responseData: Data?

    var decoder: JSONDecoder { JSONDecoder() }
    var logger: (any GitHubLogger)? { nil }

    func apiAsync(_ endpoint: String, timeout: TimeInterval) async -> Data? { nil }
    func apiPaginated(_ endpoint: String, timeout: TimeInterval) async -> Data? { nil }
    func raw(_ endpoint: String, timeout: TimeInterval) async -> Data? {
        callCount += 1
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

// MARK: - Tests

/// Integration-style tests verifying that `PollResultBuilder.buildGroupState`
/// triggers ZIP prefetch behaviour correctly through the `enqueueZIP` closure.
///
/// These tests use a real `ZIPPrefetchQueue` with a fake transport and a
/// temporary `DiskZIPCache` so they exercise the full deduplication and
/// caching path without hitting the network.
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

    // MARK: - Helpers

    /// Builds a `WorkflowActionGroup` with a single run for testing.
    /// Mirrors the helper in `PollResultBuilderGroupStateTests`.
    private func makeGroup(
        id runID: Int,
        sha: String = "aabbcc",
        groupStatus: GroupStatus = .completed,
        conclusion: String = "success",
        repo: String = "owner/repo",
        isDimmed: Bool = false
    ) -> WorkflowActionGroup {
        let resolvedJobStatus: JobStatus = groupStatus == .completed ? .completed : .inProgress
        let jobConclusion: JobConclusion? = groupStatus == .completed
            ? JobConclusion(rawString: conclusion)
            : nil
        let job = ActiveJob(
            id: runID * 10,
            name: "job-\(runID)",
            status: resolvedJobStatus,
            conclusion: jobConclusion
        )
        let runConclusion: JobConclusion? = groupStatus == .completed
            ? JobConclusion(rawString: conclusion)
            : nil
        return WorkflowActionGroup(
            headSha: sha,
            label: String(sha.prefix(7)),
            title: "commit message",
            headBranch: "main",
            repo: repo,
            runs: [
                WorkflowRunRef(
                    id: runID, name: "CI", status: resolvedJobStatus,
                    conclusion: runConclusion, htmlUrl: nil)
            ],
            jobs: [job],
            firstJobStartedAt: Date(timeIntervalSinceReferenceDate: 0),
            lastJobCompletedAt: groupStatus == .completed
                ? Date(timeIntervalSinceReferenceDate: 60) : nil,
            isDimmed: isDimmed
        )
    }

    /// Builds a group with **multiple** runs for testing the per-run ZIP enqueue.
    private func makeMultiRunGroup(
        runIDs: [Int],
        sha: String = "multi-run",
        repo: String = "owner/repo"
    ) -> WorkflowActionGroup {
        let runs: [WorkflowRunRef] = runIDs.map { runID in
            WorkflowRunRef(
                id: runID, name: "CI-\(runID)", status: .completed,
                conclusion: .success, htmlUrl: nil)
        }
        let jobs: [ActiveJob] = runIDs.map { runID in
            ActiveJob(
                id: runID * 10, name: "job-\(runID)", status: .completed,
                conclusion: .success)
        }
        return WorkflowActionGroup(
            headSha: sha,
            label: String(sha.prefix(7)),
            title: "multi-run commit",
            headBranch: "main",
            repo: repo,
            runs: runs,
            jobs: jobs,
            firstJobStartedAt: Date(timeIntervalSinceReferenceDate: 0),
            lastJobCompletedAt: Date(timeIntervalSinceReferenceDate: 120),
            isDimmed: false
        )
    }

    /// Creates a `ZIPPrefetchQueue` backed by a fake transport and a temp disk cache.
    private func makeQueue(
        transport: TestFakeTransport
    ) -> (ZIPPrefetchQueue, DiskZIPCache) {
        let disk = DiskZIPCache(cacheDir: tempDir)
        let queue = ZIPPrefetchQueue(
            diskCache: disk,
            transport: transport
        )
        return (queue, disk)
    }

    // MARK: - Test cases

    /// In-progress group does not trigger any ZIP prefetch requests.
    @MainActor
    func testInProgressGroupDoesNotRequestZIP() async throws {
        let transport = TestFakeTransport()
        transport.responseData = Data()
        let (queue, _) = makeQueue(transport: transport)
        let liveGroup = makeGroup(id: 100, groupStatus: .inProgress)

        let _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            fetchGroups: { _ in [liveGroup] },
            enrichJobs: { $0 },
            enqueueZIP: { runID, scope, isCompleted in
                await queue.enqueue(runID: runID, scope: scope, isCompleted: isCompleted)
            }
        )

        // Allow background tasks to drain
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(
            transport.callCount, 0,
            "In-progress group must not trigger ZIP fetches")
    }

    /// Completed group triggers one ZIP prefetch per run.
    @MainActor
    func testCompletedGroupRequestsZIPPerRun() async throws {
        let transport = TestFakeTransport()
        transport.responseData = Data()
        let (queue, _) = makeQueue(transport: transport)
        let completedGroup = makeGroup(id: 200, groupStatus: .completed)

        let _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            fetchGroups: { _ in [completedGroup] },
            enrichJobs: { $0 },
            enqueueZIP: { runID, scope, isCompleted in
                await queue.enqueue(runID: runID, scope: scope, isCompleted: isCompleted)
            }
        )

        // Allow background tasks to drain
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            transport.callCount, 1,
            "Completed group with 1 run must trigger exactly 1 ZIP fetch")
    }

    /// Completed group with multiple runs triggers one ZIP prefetch per run.
    @MainActor
    func testCompletedGroupWithMultipleRunsRequestsZIPPerRun() async throws {
        let transport = TestFakeTransport()
        transport.responseData = Data()
        let (queue, _) = makeQueue(transport: transport)
        let multiRunGroup = makeMultiRunGroup(runIDs: [10, 20])

        let _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            fetchGroups: { _ in [multiRunGroup] },
            enrichJobs: { $0 },
            enqueueZIP: { runID, scope, isCompleted in
                await queue.enqueue(runID: runID, scope: scope, isCompleted: isCompleted)
            }
        )

        // Allow background tasks to drain
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            transport.callCount, 2,
            "Completed group with 2 runs must trigger exactly 2 ZIP fetches")
    }

    /// Completed group ZIPs are stored on disk after processing.
    @MainActor
    func testCompletedGroupStoresZIPsOnDisk() async throws {
        let transport = TestFakeTransport()
        let zipData = Data("fake-zip-bytes".utf8)
        transport.responseData = zipData
        let (queue, disk) = makeQueue(transport: transport)
        let completedGroup = makeGroup(id: 300, groupStatus: .completed)

        let _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            fetchGroups: { _ in [completedGroup] },
            enrichJobs: { $0 },
            enqueueZIP: { runID, scope, isCompleted in
                await queue.enqueue(runID: runID, scope: scope, isCompleted: isCompleted)
            }
        )

        // Allow background tasks to drain
        try await Task.sleep(nanoseconds: 100_000_000)
        let onDisk = await disk.get(runID: 300)
        XCTAssertNotNil(onDisk, "Completed group run ZIP must be stored on disk")
        XCTAssertEqual(onDisk, zipData, "Disk cache must contain the exact ZIP bytes")
    }

    /// Processing the same completed group again does not re-download cached ZIPs.
    @MainActor
    func testReProcessingCompletedGroupDoesNotRedownload() async throws {
        let transport = TestFakeTransport()
        transport.responseData = Data()
        let (queue, _) = makeQueue(transport: transport)
        let completedGroup = makeGroup(id: 400, groupStatus: .completed)

        // First pass — should trigger 1 fetch
        let _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [:],
            fetchGroups: { _ in [completedGroup] },
            enrichJobs: { $0 },
            enqueueZIP: { runID, scope, isCompleted in
                await queue.enqueue(runID: runID, scope: scope, isCompleted: isCompleted)
            }
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        let firstCallCount = transport.callCount

        // Second pass — should NOT trigger another fetch (ZIP is already cached)
        let _ = await PollResultBuilder.buildGroupState(
            snapPrevGroups: [:],
            snapGroupCache: [completedGroup.id: completedGroup.copying(isDimmed: true)],
            fetchGroups: { _ in [] },  // No new groups fetched
            enrichJobs: { $0 },
            enqueueZIP: { runID, scope, isCompleted in
                await queue.enqueue(runID: runID, scope: scope, isCompleted: isCompleted)
            }
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            transport.callCount, firstCallCount,
            "Re-processing a completed group must not re-download cached ZIPs")
    }
}
