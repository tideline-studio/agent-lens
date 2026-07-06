/// A fixed-capacity key/value store that evicts the least-recently-written entry
/// when an insert would exceed `capacity`. "Recently written" — not read — because
/// the diagnostics cache it backs is refreshed on every publish, and a re-publish is
/// exactly the signal that a file is still active.
///
/// A value type: it lives inside an actor's isolation, so value semantics are simpler
/// and safer than a reference type and make it trivially testable in isolation.
struct BoundedCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    /// Keys ordered least- to most-recently written. Kept in sync with `storage`.
    private var recency: [Key] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { storage.count }

    subscript(key: Key) -> Value? { storage[key] }

    /// Inserts or updates `key`, marks it most-recently written, and evicts the oldest
    /// entry if that pushes the cache over capacity.
    mutating func set(_ key: Key, _ value: Value) {
        storage[key] = value
        touch(key)
        while storage.count > capacity, let oldest = recency.first {
            storage.removeValue(forKey: oldest)
            recency.removeFirst()
        }
    }

    mutating func removeValue(forKey key: Key) {
        storage.removeValue(forKey: key)
        recency.removeAll { $0 == key }
    }

    private mutating func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
