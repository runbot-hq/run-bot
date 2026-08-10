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

    private func makeGroupKey(
        repo: String = "owner/repo",
        sha: String = "abc123",
        event: String = "push"
    ) -> ZIPCacheGroupKey {
        ZIPCacheGroupKey(repo: repo, headSha: sha, normalizedEvent: event)
    }

    private func makeEntryKey(
        repo: String = "owner/repo",
        sha: String = "abc123",
        event: String = "push",
        runID: Int = 1,
        runAttempt: Int = 1
    ) -> ZIPCacheEntryKey {
        ZIPCacheEntryKey(
            group: makeGroupKey(repo: repo, sha: sha, event: event),
            runID: runID,
            runAttempt: runAttempt
        )
    }

    // MARK: - Miss

    func testGetMissReturnsNil() {
        let cache = makeCache()
        let result = cache.get(key: makeEntryKey(runID: 999))
        XCTAssertNil(result)
    }

    // MARK: - Write and read back

    func testSetCompletedThenGetReturnsData() throws {
        let cache = makeCache()
        let data = Data("hello-world".utf8)
        cache.set(key: makeEntryKey(runID: 1), zip: data, isCompleted: true)
        let result = cache.get(key: makeEntryKey(runID: 1))
        XCTAssertEqual(result, data)
    }

    func testSetNotCompletedDoesNotPersist() {
        let cache = makeCache()
        cache.set(key: makeEntryKey(runID: 2), zip: Data("incomplete".utf8), isCompleted: false)
        let result = cache.get(key: makeEntryKey(runID: 2))
        XCTAssertNil(result, "Incomplete runs must not be persisted to disk")
    }

    // MARK: - runAttempt distinguishes reruns

    func testDifferentRunAttemptsDontCollide() throws {
        let cache = makeCache()
        let data1 = Data("attempt-1".utf8)
        let data2 = Data("attempt-2".utf8)
        let key1 = makeEntryKey(runID: 10, runAttempt: 1)
        let key2 = makeEntryKey(runID: 10, runAttempt: 2)
        cache.set(key: key1, zip: data1, isCompleted: true)
        cache.set(key: key2, zip: data2, isCompleted: true)
        XCTAssertEqual(cache.get(key: key1), data1, "Attempt 1 must not be overwritten by attempt 2")
        XCTAssertEqual(cache.get(key: key2), data2, "Attempt 2 must be readable independently")
    }

    // MARK: - Persistence across instances

    func testPersistedDataSurvivesNewInstance() throws {
        let data = Data("persistent-data".utf8)
        let key = makeEntryKey(runID: 7)
        let cache1 = makeCache()
        cache1.set(key: key, zip: data, isCompleted: true)

        let cache2 = makeCache()
        let result = cache2.get(key: key)
        XCTAssertEqual(result, data, "Data written by cache1 must be readable by cache2")
    }

    // MARK: - File layout

    func testFileNameIncludesRunAttempt() throws {
        let cache = makeCache()
        let key = makeEntryKey(runID: 3, runAttempt: 2)
        cache.set(key: key, zip: Data("test".utf8), isCompleted: true)
        // Folder: <groupKey.folderName>/<runID>-<runAttempt>.zip
        let groupDir = tempDir.appendingPathComponent(key.group.folderName)
        let file = groupDir.appendingPathComponent("3-2.zip")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "File must be named <runID>-<runAttempt>.zip inside group folder"
        )
    }

    func testDefaultAttemptUsesAttempt1Filename() throws {
        let cache = makeCache()
        let key = makeEntryKey(runID: 5, runAttempt: 1)
        cache.set(key: key, zip: Data("x".utf8), isCompleted: true)
        let groupDir = tempDir.appendingPathComponent(key.group.folderName)
        let file = groupDir.appendingPathComponent("5-1.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - evictGroup removes all entries for that group

    func testEvictGroupRemovesGroupDir() throws {
        let cache = makeCache()
        let groupKey = makeGroupKey(sha: "deadbeef")
        let key1 = ZIPCacheEntryKey(group: groupKey, runID: 1, runAttempt: 1)
        let key2 = ZIPCacheEntryKey(group: groupKey, runID: 2, runAttempt: 1)
        cache.set(key: key1, zip: Data("a".utf8), isCompleted: true)
        cache.set(key: key2, zip: Data("b".utf8), isCompleted: true)
        cache.evictGroup(key: groupKey)
        XCTAssertNil(cache.get(key: key1), "evictGroup must remove entry 1")
        XCTAssertNil(cache.get(key: key2), "evictGroup must remove entry 2")
    }

    func testEvictGroupDoesNotRemoveOtherGroups() throws {
        let cache = makeCache()
        let groupA = makeGroupKey(sha: "aaaa")
        let groupB = makeGroupKey(sha: "bbbb")
        let keyA = ZIPCacheEntryKey(group: groupA, runID: 1, runAttempt: 1)
        let keyB = ZIPCacheEntryKey(group: groupB, runID: 1, runAttempt: 1)
        cache.set(key: keyA, zip: Data("a".utf8), isCompleted: true)
        cache.set(key: keyB, zip: Data("b".utf8), isCompleted: true)
        cache.evictGroup(key: groupA)
        XCTAssertNil(cache.get(key: keyA), "evictGroup(A) must remove A")
        XCTAssertNotNil(cache.get(key: keyB), "evictGroup(A) must not remove B")
    }

    // MARK: - LRU group eviction

    func testEvictsOldestGroupWhenOverMaxGroupCapacity() throws {
        let cache = makeCache()
        let max = DiskZIPCache.maxGroupCapacity
        // Write max + 1 groups, each with one entry
        for i in 1...(max + 1) {
            let key = ZIPCacheEntryKey(
                group: ZIPCacheGroupKey(repo: "o/r", headSha: "sha\(i)", normalizedEvent: "push"),
                runID: i,
                runAttempt: 1
            )
            cache.set(key: key, zip: Data("zip-\(i)".utf8), isCompleted: true)
            // Brief sleep so mtime ordering is deterministic on fast hardware
            Thread.sleep(forTimeInterval: 0.02)
        }
        // The oldest group (sha1) must have been evicted
        let oldest = ZIPCacheEntryKey(
            group: ZIPCacheGroupKey(repo: "o/r", headSha: "sha1", normalizedEvent: "push"),
            runID: 1, runAttempt: 1
        )
        let newest = ZIPCacheEntryKey(
            group: ZIPCacheGroupKey(repo: "o/r", headSha: "sha\(max + 1)", normalizedEvent: "push"),
            runID: max + 1, runAttempt: 1
        )
        XCTAssertNil(cache.get(key: oldest), "Oldest group must have been evicted")
        XCTAssertNotNil(cache.get(key: newest), "Newest group must survive eviction")
    }

    // MARK: - Legacy flat-file cleanup

    func testLegacyFlatFilesArePurgedOnInit() throws {
        // Plant a legacy flat file at the cache root
        let legacyFile = tempDir.appendingPathComponent("123456.zip")
        try Data("old".utf8).write(to: legacyFile)
        // Init a new cache instance — should purge legacy flat files
        _ = makeCache()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyFile.path),
            "Legacy flat *.zip files at cache root must be removed on init"
        )
    }
}
