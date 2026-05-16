/// Test-only backing store for `SortedDateSeries.probeCount`.
/// Swift does not allow stored static properties in generic types, so the
/// counter lives here as a module-level global instead.
nonisolated(unsafe) var sortedDateSeriesProbeCount: Int = 0

/// A date-sorted contiguous store keyed by `DateKey` (`Int32` yyyymmdd).
/// Replaces the `[String: Value]` price/rate caches: O(log n) `exact`
/// and `floor` (the prior-trading-day fallback), strictly less RAM than
/// `Dictionary` (no hash slack, no duplicate key storage, no separate
/// sorted index), and a `Codable` shape that loads pre-sorted from an
/// `ORDER BY date` query.
///
/// Entries are kept sorted ascending by `key` at all times. `upsert`
/// replaces an existing same-key value (last-wins), matching the old
/// `dict[date] = value` overwrite semantics.
struct SortedDateSeries<Value: Codable & Sendable & Equatable>: Sendable {
  struct Entry: Sendable {
    var key: Int32
    var value: Value
  }

  private(set) var entries: [Entry]

  /// Test-only probe counter incremented once per binary-search step in
  /// `exact` / `floor`. Lets the plan-pinning test assert logarithmic
  /// behaviour.
  ///
  /// Stored as a global because Swift does not allow stored static properties
  /// in generic types. Accessed via the computed static property
  /// `SortedDateSeries<V>.probeCount`; all specialisations share the same
  /// backing global.
  ///
  /// Incremented by the production binary-search paths but has no effect on
  /// their output; only test code reads it.
  static var probeCount: Int {
    get { sortedDateSeriesProbeCount }
    set { sortedDateSeriesProbeCount = newValue }
  }

  init() { self.entries = [] }

  /// Precondition: `entries` is already sorted ascending by key with no
  /// duplicate keys. Used by `loadCache` after an `ORDER BY date` fetch.
  init(sortedEntries: [Entry]) { self.entries = sortedEntries }

  /// Sorts and de-duplicates (last value wins for a repeated key).
  init(unsorted pairs: [(Int32, Value)]) {
    var map: [Int32: Value] = [:]
    for (dateKey, val) in pairs { map[dateKey] = val }
    self.entries = map.sorted(by: { $0.key < $1.key }).map { Entry(key: $0.key, value: $0.value) }
  }

  var isEmpty: Bool { entries.isEmpty }
  var first: Entry? { entries.first }
  var last: Entry? { entries.last }
  var sortedKeys: [Int32] { entries.map(\.key) }

  /// Index of an exact key match, or `nil`. O(log n).
  private func index(of key: Int32) -> Int? {
    var low = 0
    var high = entries.count - 1
    while low <= high {
      Self.probeCount += 1
      let mid = (low + high) / 2
      let candidate = entries[mid].key
      if candidate == key { return mid }
      if candidate < key { low = mid + 1 } else { high = mid - 1 }
    }
    return nil
  }

  /// Index of the newest entry with `key <= target`, or `nil` when the
  /// target precedes every entry. O(log n).
  private func floorIndex(_ target: Int32) -> Int? {
    var low = 0
    var high = entries.count - 1
    var result: Int?
    while low <= high {
      Self.probeCount += 1
      let mid = (low + high) / 2
      if entries[mid].key <= target {
        result = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return result
  }

  /// Value for an exact key match, else `nil`.
  func exact(_ key: Int32) -> Value? {
    index(of: key).map { entries[$0].value }
  }

  /// Value of the newest entry on or before `key` (the prior-trading-day
  /// fallback), else `nil`.
  func floor(_ key: Int32) -> Value? {
    floorIndex(key).map { entries[$0].value }
  }

  /// Key of the newest entry on or before `target`, else `nil`.
  func floorKey(_ target: Int32) -> Int32? {
    floorIndex(target).map { entries[$0].key }
  }

  /// Inserts `value` at `key`, or replaces the existing same-key value.
  /// Keeps the array sorted. O(log n) search + O(n) shift on insert.
  mutating func upsert(_ key: Int32, _ value: Value) {
    var low = 0
    var high = entries.count - 1
    while low <= high {
      let mid = (low + high) / 2
      let candidate = entries[mid].key
      if candidate == key {
        entries[mid].value = value
        return
      }
      if candidate < key { low = mid + 1 } else { high = mid - 1 }
    }
    entries.insert(Entry(key: key, value: value), at: low)
  }
}

extension SortedDateSeries: Codable {}

extension SortedDateSeries.Entry: Codable {}

extension SortedDateSeries: Equatable {}

extension SortedDateSeries.Entry: Equatable {}
