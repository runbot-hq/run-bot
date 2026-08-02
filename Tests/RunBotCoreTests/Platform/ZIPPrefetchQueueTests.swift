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
        transport: FakeTransport,
        extractor: ZipExtractor? = nil
    ) -> (ZIPPrefetchQueue, ZIPLRUCache, DiskZIPCache) {
        let mem = ZIPLRUCache()
        let disk = DiskZIPCache(cacheDir: tempDir)
        let queue = ZIPPrefetchQueue(
            memCache: mem,
            diskCache: disk,
            transport: transport,
            zipExtractor: extractor
        )
        return (queue, mem, disk)
    }

    private func successExtractor(files: [(name: String, text: String)]) -> ZipExtractor {
        { _ in .success(files) }
    }

    // MARK: - Deduplication

    func testEnqueueSameRunIDTwiceOnlyFetchesOnce() async throws {
        let transport = FakeTransport()
        transport.responseData = Data()
        let (queue, _, _) = makeQueue(
            transport: transport,
            extractor: successExtractor(files: [("f.txt", "x")])
        )
        await queue.enqueue(runID: 1, startedAt: nil, scope: "o/r", isCompleted: true)
        await queue.enqueue(runID: 1, startedAt: nil, scope: "o/r", isCompleted: true)
        // Allow background tasks to drain
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.callCount, 1, "Duplicate enqueue must be deduplicated")
    }

    func testSkipsRunIDAlreadyInMemCache() async throws {
        let transport = FakeTransport()
        transport.responseData = Data()
        let (queue, mem, _) = makeQueue(transport: transport)
        await mem.set(1, files: [("f.txt", "x")])
        await queue.enqueue(runID: 1, startedAt: nil, scope: "o/r", isCompleted: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(transport.callCount, 0, "Run already in mem cache must not trigger a fetch")
    }

    func testSkipsRunIDAlreadyOnDisk() async throws {
        let transport = FakeTransport()
        transport.responseData = Data()
        let (queue, _, disk) = makeQueue(transport: transport)
        let key = diskZIPCacheKey(runID: 1, startedAt: nil)
        await disk.set(key: key, value: [("f.txt", "x")], isCompleted: true)
        await queue.enqueue(runID: 1, startedAt: nil, scope: "o/r", isCompleted: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(transport.callCount, 0, "Run already on disk must not trigger a fetch")
    }

    // MARK: - Nil response (expired ZIP)

    func testNilResponseDoesNotCrashAndLogsOnce() async throws {
        let transport = FakeTransport()
        transport.responseData = nil // simulate expired / 404 ZIP
        let (queue, mem, _) = makeQueue(transport: transport)
        await queue.enqueue(runID: 99, startedAt: nil, scope: "o/r", isCompleted: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        // Exactly one fetch attempt; nothing written to mem cache
        XCTAssertEqual(transport.callCount, 1, "Nil response should trigger exactly one fetch attempt")
        let inMem = await mem.contains(99)
        XCTAssertFalse(inMem, "Nil response must not populate mem cache")
    }

    // MARK: - cancelAll

    func testCancelAllPreventsSubsequentEnqueue() async throws {
        let transport = FakeTransport()
        transport.responseData = Data()
        let (queue, _, _) = makeQueue(
            transport: transport,
            extractor: successExtractor(files: [("f.txt", "x")])
        )
        await queue.cancelAll()
        await queue.enqueue(runID: 5, startedAt: nil, scope: "o/r", isCompleted: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(transport.callCount, 0, "Enqueue after cancelAll must be a no-op")
    }

    // MARK: - Successful fetch populates caches

    func testSuccessfulFetchPopulatesMemAndDiskCache() async throws {
        let transport = FakeTransport()
        transport.responseData = Data()
        let files: [(name: String, text: String)] = [("step1.txt", "hello")]
        let (queue, mem, disk) = makeQueue(
            transport: transport,
            extractor: successExtractor(files: files)
        )
        await queue.enqueue(runID: 10, startedAt: "2026-01-01T00:00:00Z", scope: "o/r", isCompleted: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        let inMem = await mem.contains(10)
        let onDisk = await disk.get(key: diskZIPCacheKey(runID: 10, startedAt: "2026-01-01T00:00:00Z"))
        XCTAssertTrue(inMem, "Successful fetch must populate LRU cache")
        XCTAssertNotNil(onDisk, "Successful fetch of completed run must populate disk cache")
    }
}
