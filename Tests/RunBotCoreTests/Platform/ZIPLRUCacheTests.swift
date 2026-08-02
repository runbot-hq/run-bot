// ZIPLRUCacheTests.swift
// RunBotCoreTests
import XCTest
@testable import RunBotCore

final class ZIPLRUCacheTests: XCTestCase {

    // MARK: - Helpers

    private func makeFiles(_ n: Int) -> [(name: String, text: String)] {
        [(name: "file\(n).txt", text: "content\(n)")]
    }

    // MARK: - Basic get/set

    func testGetMissReturnsNil() async {
        let cache = ZIPLRUCache()
        let result = await cache.get(1)
        XCTAssertNil(result)
    }

    func testSetThenGetReturnsFiles() async {
        let cache = ZIPLRUCache()
        await cache.set(1, files: makeFiles(1))
        let result = await cache.get(1)
        XCTAssertEqual(result?.first?.name, "file1.txt")
    }

    func testContainsFalseOnMiss() async {
        let cache = ZIPLRUCache()
        let present = await cache.contains(42)
        XCTAssertFalse(present)
    }

    func testContainsTrueAfterSet() async {
        let cache = ZIPLRUCache()
        await cache.set(42, files: makeFiles(42))
        let present = await cache.contains(42)
        XCTAssertTrue(present)
    }

    // MARK: - LRU eviction

    func testEvictsLRUWhenAtCapacity() async {
        let cache = ZIPLRUCache()
        // Fill to maxCapacity (10)
        for i in 1...10 {
            await cache.set(i, files: makeFiles(i))
        }
        // runID 1 is LRU — inserting runID 11 should evict it
        await cache.set(11, files: makeFiles(11))
        let evicted = await cache.contains(1)
        let newest = await cache.contains(11)
        XCTAssertFalse(evicted, "runID 1 should have been evicted as LRU")
        XCTAssertTrue(newest)
    }

    func testGetPromotesEntryPreventingEviction() async {
        let cache = ZIPLRUCache()
        // Fill capacity
        for i in 1...10 {
            await cache.set(i, files: makeFiles(i))
        }
        // Promote runID 1 to MRU via get
        _ = await cache.get(1)
        // Insert runID 11 — should now evict runID 2 (new LRU), not 1
        await cache.set(11, files: makeFiles(11))
        let promoted = await cache.contains(1)
        let evicted = await cache.contains(2)
        XCTAssertTrue(promoted, "runID 1 was promoted, should not be evicted")
        XCTAssertFalse(evicted, "runID 2 should be evicted as new LRU")
    }

    func testContainsDoesNotPromote() async {
        let cache = ZIPLRUCache()
        for i in 1...10 {
            await cache.set(i, files: makeFiles(i))
        }
        // contains(1) — should NOT promote runID 1
        _ = await cache.contains(1)
        // Insert 11 — runID 1 should still be evicted (LRU)
        await cache.set(11, files: makeFiles(11))
        let shouldBeEvicted = await cache.contains(1)
        XCTAssertFalse(shouldBeEvicted, "contains() must not promote; runID 1 should be evicted")
    }

    func testUpdateExistingKeyPromotes() async {
        let cache = ZIPLRUCache()
        for i in 1...10 {
            await cache.set(i, files: makeFiles(i))
        }
        // Re-set runID 1 — promotes it to MRU
        await cache.set(1, files: makeFiles(99))
        await cache.set(11, files: makeFiles(11))
        let updated = await cache.contains(1)
        let evicted = await cache.contains(2)
        XCTAssertTrue(updated)
        XCTAssertFalse(evicted)
    }

    func testCapacityIsExactlyMaxCapacity() async {
        let cache = ZIPLRUCache()
        for i in 1...ZIPLRUCache.maxCapacity {
            await cache.set(i, files: makeFiles(i))
        }
        // All entries present, none evicted yet
        for i in 1...ZIPLRUCache.maxCapacity {
            let present = await cache.contains(i)
            XCTAssertTrue(present, "runID \(i) should still be cached")
        }
    }
}
