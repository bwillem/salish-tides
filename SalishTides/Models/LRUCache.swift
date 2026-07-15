/// Bounded most-recently-used cache: reads refresh recency, inserts evict the
/// least-recently-used entry beyond `limit`. Not thread-safe — confine it to
/// its owner's actor (LiveDataService keeps one per slice kind).
struct LRUCache<Key: Hashable, Value> {
    private var store: [Key: Value] = [:]
    private var order: [Key] = []   // most recent last
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    /// The cached value, marking the key most-recently-used.
    mutating func value(for key: Key) -> Value? {
        guard let value = store[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        store[key] = value
        touch(key)
        if order.count > limit {
            store[order.removeFirst()] = nil
        }
    }

    mutating func removeValue(for key: Key) {
        store[key] = nil
        order.removeAll { $0 == key }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
