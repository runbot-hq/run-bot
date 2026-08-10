// ZIPPrefetchQueueTests.swift
// RunBotCoreTests
import XCTest
import GitHubClient
@testable import RunBotCore

// MARK: - Fake transport

/// Counts calls and returns configurable data or nil (simulate 404).
final class FakeTransport: GitHubTransportProtocol, @unchecked Sendable {
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

final class ZIPPrefetchQueueTests: XCTestCase {

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

    private func makeQueue(
        transport: FakeTransport
    ) -> (ZIPPrefetchQueue, DiskZIPCache) {
        let disk = DiskZIPCache(cacheDir: tempDir)
        let queue = ZIPPrefetchQueue(diskCache: disk, transport: transport)
        return (queue, disk)
    }

    private func makeKey(runID: Int, runAttempt: Int = 1) -> ZIPCacheEntryKey {
        ZIPCacheEntryKey(
            group: ZIPCacheGroupKey(repo: "o/r", headSha: "sha\(runID)", normalizedEvent: "push"),
            runID: runID,
            runAttempt: runAttempt
        )
    }

    // MARK: - Deduplication

    func testEnqueueSameEntryTwiceOnlyFetchesOnce() async throws {
        let transport = FakeTransport()
        transport.responseData = Data()
        let (queue, _) = makeQueue(transport: transport)
        let key = makeKey(runID: 1)
        await queue.enqueue(entryKey: key, scope: "o/r", isCompleted: true)
        await queue.enqueue(entryKey: key, scope: "o/r", isCompleted: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.callCount, 1, "Duplicate enqueue must be deduplicated")
    }

    func testSkipsEntryAlreadyOnDisk() async throws {
        let transport = FakeTransport()
        transport.responseData = Data()
        let (queue, disk) = makeQueue(transport: transport)
        let key = makeKey(runID: 1)
        await disk.set(key: key, zip: Data("test".utf8), isCompleted: true)
        await queue.enqueue(entryKey: key, scope: "o/r", isCompleted: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(transport.callCount, 0, "Entry already on disk must not trigger a fetch")
    }

    // MARK: - Different runAttempts are independent entries

    func testDifferentRunAttemptsEnqueuedIndependently() async throws {
        let transport = FakeTransport()
        transport.responseData = Data()
        let (queue, _) = makeQueue(transport: transport)
        // Same runID, different attempts — each should fetch once
        await queue.enqueue(entryKey: makeKey(runID: 10, runAttempt: 1), scope: "o/r", isCompleted: true)
        await queue.enqueue(entryKey: makeKey(runID: 10, runAttempt: 2), scope: "o/r", isCompleted: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.callCount, 2, "Each runAttempt must produce its own fetch")
    }

    // MARK: - Nil response (expired ZIP)

    func testNilResponseDoesNotCrashAndFetchesOnce() async throws {
        let transport = FakeTransport()
        transport.responseData = nil
        let (queue, _) = makeQueue(transport: transport)
        await queue.enqueue(entryKey: makeKey(runID: 99), scope: "o/r", isCompleted: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.callCount, 1, "Nil response should trigger exactly one fetch attempt")
    }

    // MARK: - cancelAll

    func testCancelAllPreventsSubsequentEnqueue() async throws {
        let transport = FakeTransport()
        transport.responseData = Data()
        let (queue, _) = makeQueue(transport: transport)
        await queue.cancelAll()
        await queue.enqueue(entryKey: makeKey(runID: 5), scope: "o/r", isCompleted: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(transport.callCount, 0, "Enqueue after cancelAll must be a no-op")
    }

    // MARK: - Successful fetch populates disk cache

    func testSuccessfulFetchPopulatesDiskCache() async throws {
        let transport = FakeTransport()
        let zipData = Data("fake-zip-bytes".utf8)
        transport.responseData = zipData
        let (queue, disk) = makeQueue(transport: transport)
        let key = makeKey(runID: 10)
        await queue.enqueue(entryKey: key, scope: "o/r", isCompleted: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        let onDisk = await disk.get(key: key)
        XCTAssertNotNil(onDisk, "Successful fetch of completed run must populate disk cache")
        XCTAssertEqual(onDisk, zipData, "Disk cache must contain the exact bytes returned by transport")
    }

    // MARK: - Incomplete run is not cached

    func testIncompleteRunNotCached() async throws {
        let transport = FakeTransport()
        transport.responseData = Data("zip".utf8)
        let (queue, disk) = makeQueue(transport: transport)
        let key = makeKey(runID: 20)
        await queue.enqueue(entryKey: key, scope: "o/r", isCompleted: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        // Fetch was attempted (transport called) but disk must remain empty
        XCTAssertEqual(transport.callCount, 1, "Incomplete run should still attempt fetch")
        let diskResult = await disk.get(key: key)
        XCTAssertNil(diskResult, "Incomplete run ZIP must not be written to disk")
    }
}
