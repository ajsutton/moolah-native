import Foundation

/// Test-only backing store for `SortedDateSeries.probeCount`.
/// Swift does not allow stored static properties in generic types, so the
/// counter lives here as a module-level global instead.
nonisolated(unsafe) var _sortedDateSeriesProbeCount: Int = 0

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
struct SortedDateSeries<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
  struct Entry: Codable, Sendable, Equatable {
    var key: Int32
    var value: Value
  }

  private(set) var entries: [Entry]

  /// Test-only probe counter incremented once per binary-search step in
  /// `exact` / `floor`. Lets the plan-pinning test assert logarithmic
  /// behaviour. Not used in production logic.
  ///
  /// Stored as a global because Swift does not allow stored static properties
  /// in generic types. Accessed via the type alias `SortedDateSeries<V>.probeCount`
  /// which delegates to this global.
  static var probeCount: Int {
    get { _sortedDateSeriesProbeCount }
    set { _sortedDateSeriesProbeCount = newValue }
  }

  init() { self.entries = [] }

  /// Precondition: `entries` is already sorted ascending by key with no
  /// duplicate keys. Used by `loadCache` after an `ORDER BY date` fetch.
  init(sortedEntries: [Entry]) { self.entries = sortedEntries }

  /// Sorts and de-duplicates (last value wins for a repeated key).
  init(unsorted pairs: [(Int32, Value)]) {
    var map: [Int32: Value] = [:]
    for (k, v) in pairs { map[k] = v }
    self.entries = map.keys.sorted().map { Entry(key: $0, value: map[$0]!) }
  }

  var isEmpty: Bool { entries.isEmpty }
  var first: Entry? { entries.first }
  var last: Entry? { entries.last }
  var sortedKeys: [Int32] { entries.map(\.key) }

  /// Index of an exact key match, or `nil`. O(log n).
  private func index(of key: Int32) -> Int? {
    var lo = 0
    var hi = entries.count - 1
    while lo <= hi {
      Self.probeCount += 1
      let mid = (lo + hi) / 2
      let k = entries[mid].key
      if k == key { return mid }
      if k < key { lo = mid + 1 } else { hi = mid - 1 }
    }
    return nil
  }

  /// Index of the newest entry with `key <= target`, or `nil` when the
  /// target precedes every entry. O(log n).
  private func floorIndex(_ target: Int32) -> Int? {
    var lo = 0
    var hi = entries.count - 1
    var result: Int?
    while lo <= hi {
      Self.probeCount += 1
      let mid = (lo + hi) / 2
      if entries[mid].key <= target {
        result = mid
        lo = mid + 1
      } else {
        hi = mid - 1
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
    var lo = 0
    var hi = entries.count - 1
    while lo <= hi {
      let mid = (lo + hi) / 2
      let k = entries[mid].key
      if k == key {
        entries[mid].value = value
        return
      }
      if k < key { lo = mid + 1 } else { hi = mid - 1 }
    }
    entries.insert(Entry(key: key, value: value), at: lo)
  }
}
