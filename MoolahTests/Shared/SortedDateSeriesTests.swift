import Foundation
import Testing

@testable import Moolah

@Suite("SortedDateSeries", .serialized)
struct SortedDateSeriesTests {
  @Test("exact returns the value only for an exact key match")
  func exact() {
    var series = SortedDateSeries<Int>()
    series.upsert(1, forKey: 20_240_101)
    series.upsert(3, forKey: 20_240_103)
    #expect(series.exact(20_240_101) == 1)
    #expect(series.exact(20_240_103) == 3)
    #expect(series.exact(20_240_102) == nil)
  }

  @Test("floor returns the newest entry on or before the key")
  func floor() {
    var series = SortedDateSeries<Int>()
    series.upsert(1, forKey: 20_240_101)
    series.upsert(5, forKey: 20_240_105)
    series.upsert(10, forKey: 20_240_110)
    #expect(series.floor(20_240_100) == nil)  // before first
    #expect(series.floor(20_240_101) == 1)  // exact
    #expect(series.floor(20_240_107) == 5)  // gap → prior
    #expect(series.floor(20_240_999) == 10)  // after last → last
  }

  @Test("upsert keeps entries sorted and replaces duplicates")
  func upsertReplaces() {
    var series = SortedDateSeries<Int>()
    series.upsert(3, forKey: 20_240_103)
    series.upsert(1, forKey: 20_240_101)
    series.upsert(33, forKey: 20_240_103)  // replace
    #expect(series.sortedKeys == [20_240_101, 20_240_103])
    #expect(series.exact(20_240_103) == 33)
  }

  @Test("init(unsorted:) sorts and de-duplicates last-wins")
  func initUnsorted() {
    let series = SortedDateSeries<Int>(unsorted: [
      (20_240_103, 3), (20_240_101, 1), (20_240_103, 33),
    ])
    #expect(series.sortedKeys == [20_240_101, 20_240_103])
    #expect(series.exact(20_240_103) == 33)
  }

  @Test("first/last/isEmpty")
  func bounds() {
    var series = SortedDateSeries<Int>()
    #expect(series.isEmpty)
    series.upsert(5, forKey: 20_240_105)
    series.upsert(1, forKey: 20_240_101)
    #expect(series.first?.key == 20_240_101)
    #expect(series.last?.key == 20_240_105)
    #expect(!series.isEmpty)
  }

  @Test("plan-pin: floor does not scan linearly")
  func floorIsLogarithmic() {
    var series = SortedDateSeries<Int>()
    for offset in 0..<4_000 { series.upsert(offset, forKey: Int32(20_000_000 + offset)) }
    SortedDateSeries<Int>.probeCount = 0
    // 1,000 mixed queries (gaps + exacts) over a 4,000-entry series.
    for query in 0..<1_000 { _ = series.floor(Int32(20_000_000 + query * 4)) }
    // Linear-scan-after-sort would be >> 1_000 * 4_000 probes. A binary
    // search is ~1_000 * ceil(log2(4_000)) ≈ 12_000. Cap generously.
    #expect(SortedDateSeries<Int>.probeCount < 40_000)
  }

  @Test("Codable round-trips")
  func codable() throws {
    var series = SortedDateSeries<Int>()
    series.upsert(1, forKey: 20_240_101)
    series.upsert(3, forKey: 20_240_103)
    let data = try JSONEncoder().encode(series)
    let back = try JSONDecoder().decode(SortedDateSeries<Int>.self, from: data)
    #expect(back == series)
  }

  @Test("empty series returns nil for all lookup methods")
  func emptySeriesLookup() {
    let series = SortedDateSeries<Int>()
    #expect(series.exact(20_240_101) == nil)
    #expect(series.floor(20_240_101) == nil)
    #expect(series.floorKey(20_240_101) == nil)
  }
}
