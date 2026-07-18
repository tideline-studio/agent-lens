@testable import LSPClient
import XCTest

/// BoundedCache backs the diagnostics cache; these protect the contract that lets a
/// long-lived daemon cache diagnostics without growing memory without bound.
final class BoundedCacheTests: XCTestCase {

    func testStoresAndRetrievesValues() {
        var cache = BoundedCache<String, Int>(capacity: 3)
        cache.set("a", 1)
        cache.set("b", 2)
        XCTAssertEqual(cache["a"], 1)
        XCTAssertEqual(cache["b"], 2)
        XCTAssertNil(cache["missing"])
        XCTAssertEqual(cache.count, 2)
    }

    func testEvictsLeastRecentlyWrittenPastCapacity() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.set("a", 1)
        cache.set("b", 2)
        cache.set("c", 3)  // exceeds capacity → "a" (oldest) evicted

        XCTAssertNil(cache["a"], "oldest entry should be evicted")
        XCTAssertEqual(cache["b"], 2)
        XCTAssertEqual(cache["c"], 3)
        XCTAssertEqual(cache.count, 2, "cache must not grow past capacity")
    }

    func testRewritingAKeyRefreshesItsRecency() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.set("a", 1)
        cache.set("b", 2)
        cache.set("a", 10)  // refresh "a" → "b" is now oldest
        cache.set("c", 3)   // exceeds capacity → "b" evicted, not "a"

        XCTAssertEqual(cache["a"], 10, "refreshed key should survive eviction")
        XCTAssertNil(cache["b"], "the now-oldest key should be evicted")
        XCTAssertEqual(cache["c"], 3)
        XCTAssertEqual(cache.count, 2)
    }

    func testRemoveFreesASlot() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.set("a", 1)
        cache.set("b", 2)
        cache.removeValue(forKey: "a")
        cache.set("c", 3)  // room exists now → "b" retained

        XCTAssertNil(cache["a"])
        XCTAssertEqual(cache["b"], 2, "remove should free a slot rather than evict")
        XCTAssertEqual(cache["c"], 3)
        XCTAssertEqual(cache.count, 2)
    }

    func testCapacityIsAtLeastOne() {
        var cache = BoundedCache<String, Int>(capacity: 0)
        cache.set("a", 1)
        XCTAssertEqual(cache["a"], 1, "a zero capacity is clamped to 1, not unusable")
        XCTAssertEqual(cache.count, 1)
    }
}
