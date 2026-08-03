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

    // MARK: - Miss

    func testGetMissReturnsNil() async {
        let cache = makeCache()
        let result = await cache.get(runID: 999)
        XCTAssertNil(result)
    }

    // MARK: - Write and read back

    func testSetCompletedThenGetReturnsData() async throws {
        let cache = makeCache()
        let data = Data("hello-world".utf8)
        await cache.set(runID: 1, zip: data, isCompleted: true)
        let result = await cache.get(runID: 1)
        XCTAssertEqual(result, data)
    }

    func testSetNotCompletedDoesNotPersist() async {
        let cache = makeCache()
        await cache.set(runID: 2, zip: Data("incomplete".utf8), isCompleted: false)
        let result = await cache.get(runID: 2)
        XCTAssertNil(result, "Incomplete runs must not be persisted to disk")
    }

    // MARK: - Persistence across instances

    func testPersistedDataSurvivesNewInstance() async throws {
        let data = Data("persistent-data".utf8)
        let cache1 = makeCache()
        await cache1.set(runID: 7, zip: data, isCompleted: true)

        // New instance pointing at same dir
        let cache2 = makeCache()
        let result = await cache2.get(runID: 7)
        XCTAssertEqual(result, data,
            "Data written by cache1 must be readable by cache2")
    }

    // MARK: - Eviction

    func testEvictsOldestWhenOverMaxEntries() async throws {
        let cache = makeCache()
        // Write maxEntries + 1 completed items
        let max = DiskZIPCache.maxCapacity
        for i in 1...(max + 1) {
            await cache.set(runID: i, zip: Data("content-\(i)".utf8), isCompleted: true)
            // Small sleep so mtime ordering is deterministic on fast machines
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // First entry should be evicted
        let evicted = await cache.get(runID: 1)
        let newest = await cache.get(runID: max + 1)
        XCTAssertNil(evicted, "Oldest entry should have been evicted")
        XCTAssertNotNil(newest)
    }

    // MARK: - Key format

    func testKeyIsRunIDDotZip() async {
        let cache = makeCache()
        await cache.set(runID: 3, zip: Data("test".utf8), isCompleted: true)
        let file = tempDir.appendingPathComponent("3.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "File must be named <runID>.zip")
        let result = await cache.get(runID: 3)
        XCTAssertNotNil(result, "runID-based key must round-trip through disk cache")
    }
}
