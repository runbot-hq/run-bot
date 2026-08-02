// DiskZIPCacheTests.swift
// RunBotCoreTests
import XCTest
@testable import RunBotCore

final class DiskZIPCacheTests: XCTestCase {

    // MARK: - Helpers

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

    private func makeCache() -> DiskZIPCache {
        DiskZIPCache(cacheDir: tempDir)
    }

    private func makeFiles(_ n: Int) -> [(name: String, text: String)] {
        [(name: "file\(n).txt", text: "body\(n)")]
    }

    // MARK: - Miss

    func testGetMissReturnsNil() async {
        let cache = makeCache()
        let result = await cache.get(key: "missing-key")
        XCTAssertNil(result)
    }

    // MARK: - Write and read back

    func testSetCompletedThenGetReturnsFiles() async throws {
        let cache = makeCache()
        let files = makeFiles(1)
        await cache.set(key: "run-1", value: files, isCompleted: true)
        let result = await cache.get(key: "run-1")
        XCTAssertEqual(result?.first?.name, "file1.txt")
        XCTAssertEqual(result?.first?.text, "body1")
    }

    func testSetNotCompletedDoesNotPersist() async {
        let cache = makeCache()
        await cache.set(key: "run-incomplete", value: makeFiles(2), isCompleted: false)
        let result = await cache.get(key: "run-incomplete")
        XCTAssertNil(result, "Incomplete runs must not be persisted to disk")
    }

    // MARK: - Persistence across instances

    func testPersistedDataSurvivesNewInstance() async throws {
        let files = makeFiles(7)
        let cache1 = makeCache()
        await cache1.set(key: "run-7", value: files, isCompleted: true)

        // New instance pointing at same dir
        let cache2 = makeCache()
        let result = await cache2.get(key: "run-7")
        XCTAssertEqual(result?.first?.name, "file7.txt",
            "Data written by cache1 must be readable by cache2")
    }

    // MARK: - Eviction

    func testEvictsOldestWhenOverMaxEntries() async throws {
        let cache = makeCache()
        // Write maxEntries + 1 completed items
        let max = DiskZIPCache.maxCapacity
        for i in 1...(max + 1) {
            await cache.set(key: "run-\(i)", value: makeFiles(i), isCompleted: true)
            // Small sleep so mtime ordering is deterministic on fast machines
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        // First entry should be evicted
        let evicted = await cache.get(key: "run-1")
        let newest = await cache.get(key: "run-\(max + 1)")
        XCTAssertNil(evicted, "Oldest entry should have been evicted")
        XCTAssertNotNil(newest)
    }

    // MARK: - Key sanitisation

    func testDiskZIPCacheKeyRoundTrips() async {
        let cache = makeCache()
        // diskZIPCacheKey always sanitises colons and slashes — use it as production code does
        let key = diskZIPCacheKey(runID: 3, startedAt: "2026-01-01T00:00:00Z")
        await cache.set(key: key, value: makeFiles(3), isCompleted: true)
        let result = await cache.get(key: key)
        XCTAssertNotNil(result, "Sanitised key from diskZIPCacheKey must round-trip through disk cache")
    }
}
